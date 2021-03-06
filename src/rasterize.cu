/**
 * @file      rasterize.cu
 * @brief     CUDA-accelerated rasterization pipeline.
 * @authors   Skeleton code: Yining Karl Li, Kai Ninomiya, Shuai Shao (Shrek)
 * @date      2012-2016
 * @copyright University of Pennsylvania & STUDENT
 */

#include <random>
#include <functional>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cuda.h>
#include <cuda_runtime.h>
#include <thrust/random.h>
#include <util/checkCUDAError.h>
#include <util/tiny_gltf_loader.h>
#include "rasterizeTools.h"
#include "rasterize.h"
#include <glm/gtc/quaternion.hpp>
#include <glm/gtc/matrix_transform.hpp>


#define TILE_SIZE 8
#define TILE_TRI_LIST_SCALE 0.1f
#define TRI_LIST_SCALE_THRESHOLD 100

#define ROUND_UP_DIV(x, n) (((x) + (n) - 1) / (n))


namespace {

	typedef unsigned short VertexIndex;
	typedef glm::vec3 VertexAttributePosition;
	typedef glm::vec3 VertexAttributeNormal;
	typedef glm::vec2 VertexAttributeTexcoord;
	typedef unsigned char TextureData;

	typedef unsigned char BufferByte;

	enum PrimitiveType{
		Point = 1,
		Line = 2,
		Triangle = 3
	};

	struct VertexOut {
		glm::vec4 pos;

		// TODO: add new attributes to your VertexOut
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		 glm::vec3 eyePos;	// eye space position used for shading
		 glm::vec3 eyeNor;	// eye space normal used for shading, cuz normal will go wrong after perspective transformation
		// glm::vec3 col;
		 glm::vec2 texcoord0;
		 TextureData* dev_diffuseTex = NULL;
		 int diffuseTexWidth;
		 int diffuseTexHeight;
		// ...
	};

	struct Primitive {
		PrimitiveType primitiveType = Triangle;	// C++ 11 init
		VertexOut v[3];
	};

	struct Fragment {
		//glm::vec3 color;

		// TODO: add new attributes to your Fragment
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		glm::vec3 eyePos;	// eye space position used for shading
		glm::vec3 eyeNor;
		VertexAttributeTexcoord texcoord0;
		TextureData* dev_diffuseTex;
		int diffuseTexWidth;
		int diffuseTexHeight;
		int shouldShade;
		float ssaoFactor;
		// ...
	};

	struct PrimitiveDevBufPointers {
		int primitiveMode;	//from tinygltfloader macro
		PrimitiveType primitiveType;
		int numPrimitives;
		int numIndices;
		int numVertices;

		// Vertex In, const after loaded
		VertexIndex* dev_indices;
		VertexAttributePosition* dev_position;
		VertexAttributeNormal* dev_normal;
		VertexAttributeTexcoord* dev_texcoord0;

		// Materials, add more attributes when needed
		int diffuseTexWidth;
		int diffuseTexHeight;
		TextureData* dev_diffuseTex;
		// TextureData* dev_specularTex;
		// TextureData* dev_normalTex;
		// ...

		// Vertex Out, vertex used for rasterization, this is changing every frame
		VertexOut* dev_verticesOut;

		// TODO: add more attributes when needed
	};

}

static std::map<std::string, std::vector<PrimitiveDevBufPointers>> mesh2PrimitivesMap;


static int width = 0;
static int height = 0;

static int totalNumPrimitives = 0;
static Primitive *dev_primitives = NULL;
static Fragment *dev_fragmentBuffer = NULL;
static glm::vec3 *dev_framebuffer = NULL;

static float *dev_depth = NULL;	// you might need this buffer when doing depth test

// Tile-based rasterization
static int numTilesX = 0;
static int numTilesY = 0;
static int triListSize = 0;
static int *dev_primCounts = nullptr; // one entry per tile
static int *dev_tileTriLists = nullptr;

// SSAO
extern float sampleKernelRadius;
static const int numSamples = 64;
static const int noiseTexSize1D = 4;
// random points in a upper hemisphere whose z axis will be rotated to align
// with pixel normal in eye space
static glm::vec3 *dev_samples = nullptr;
// A 4x4 noise texture. Each pixel contains an x-axis randomly rotated in the x-y plane
// Will be tiled across the entire frame buffer
static glm::vec3 *dev_noiseTex = nullptr;

/**
 * Kernel that writes the image to the OpenGL PBO directly.
 */
__global__ 
void sendImageToPBO(uchar4 *pbo, int w, int h, glm::vec3 *image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + y * w;
	int outIdx = w - x - 1 + (h - y - 1) * w;

    if (x < w && y < h) {
        glm::vec3 color;
        color.x = glm::clamp(image[index].x, 0.0f, 1.0f) * 255.0;
        color.y = glm::clamp(image[index].y, 0.0f, 1.0f) * 255.0;
        color.z = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
        // Each thread writes one pixel location in the texture (textel)
        pbo[outIdx].w = 0;
		pbo[outIdx].x = color.x;
		pbo[outIdx].y = color.y;
		pbo[outIdx].z = color.z;
    }
}

/** 
* Writes fragment colors to the framebuffer
*/
__global__
void render(int w, int h, Fragment *fragmentBuffer, glm::vec3 *framebuffer) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h && fragmentBuffer[index].shouldShade) {
        //framebuffer[index] = fragmentBuffer[index].color;

		// TODO: add your fragment shader code here
		// Phone shading
		const glm::vec3 lightDir = glm::normalize(glm::vec3(1.f, 1.f, 1.f)); // in eye space
		const glm::vec3 ambientColor(1.f, 1.f, 1.f);
		glm::vec3 diffuseColor;
		const glm::vec3 specularColor(1.f, 1.f, 1.f);
		const float specExp = 20.f;
		const float Ka = 0.1f;
		const float Kd = 0.5f;
		const float Ks = 0.5f;

		if (fragmentBuffer[index].dev_diffuseTex)
		{
			int width = fragmentBuffer[index].diffuseTexWidth;
			int height = fragmentBuffer[index].diffuseTexHeight;
			glm::vec2 uv = fragmentBuffer[index].texcoord0;
			float fx = uv.x * width - 0.5f;
			float fy = uv.y * height - 0.5f;
			float wx = fx - glm::floor(fx);
			float wy = fy - glm::floor(fy);
			int x = glm::min(width - 2, glm::max(0, static_cast<int>(fx)));
			int y = glm::min(height - 2, glm::max(0, static_cast<int>(fy)));
			int i00 = y * width + x;
			int i10 = y * width + x + 1;
			int i01 = (y + 1) * width + x;
			int i11 = (y + 1) * width + x + 1;
			const TextureData *tex = fragmentBuffer[index].dev_diffuseTex;
			glm::vec3 p00(tex[i00 * 3] / 255.f, tex[i00 * 3 + 1] / 255.f, tex[i00 * 3 + 2] / 255.f);
			glm::vec3 p10(tex[i10 * 3] / 255.f, tex[i10 * 3 + 1] / 255.f, tex[i10 * 3 + 2] / 255.f);
			glm::vec3 p01(tex[i01 * 3] / 255.f, tex[i01 * 3 + 1] / 255.f, tex[i01 * 3 + 2] / 255.f);
			glm::vec3 p11(tex[i11 * 3] / 255.f, tex[i11 * 3 + 1] / 255.f, tex[i11 * 3 + 2] / 255.f);
			diffuseColor = (1.f - wy) * ((1.f - wx) * p00 + wx * p10) + wy * ((1.f - wx) * p01 + wx * p11);
		}
		else
		{
			diffuseColor = glm::vec3(1.f, 1.f, 1.f);
		}

		glm::vec3 eyePos = fragmentBuffer[index].eyePos;
		glm::vec3 eyeNor = fragmentBuffer[index].eyeNor;

		glm::vec3 h = glm::normalize(lightDir - eyePos);
		float costhetah = glm::max(0.f, glm::dot(h, eyeNor));
		float costheta = glm::max(0.f, glm::dot(lightDir, eyeNor));

		framebuffer[index] =
			fragmentBuffer[index].ssaoFactor * (
			Ka * ambientColor +
			Kd * diffuseColor * costheta +
			Ks * specularColor * powf(costhetah, specExp));
			//glm::vec3(fragmentBuffer[index].ssaoFactor);
    }
}

__device__ glm::mat3 coordinateSystemZFromZX(const glm::vec3 &z, const glm::vec3 &x)
{
	glm::vec3 t = glm::normalize(x - glm::dot(z, x) * z);
	glm::vec3 b = glm::cross(z, t);
	return glm::mat3(t, b, z);
}

__global__ void ssaoBlur(int width, int height, int blurSize, Fragment *fragmentBuffer)
{
	extern __shared__ float s_ssaoFactors[];

	int padding = blurSize >> 1;
	int startX = blockIdx.x * (blockDim.x - padding * 2) - padding;
	int startY = blockIdx.y * (blockDim.y - padding * 2) - padding;
	int gx = startX + threadIdx.x;
	int gy = startY + threadIdx.y;
	
	if (gx >= 0 && gx < width && gy >= 0 && gy < height)
	{
		s_ssaoFactors[threadIdx.y * blockDim.x + threadIdx.x] = fragmentBuffer[gy * width + gx].ssaoFactor;
	}
	else
	{
		s_ssaoFactors[threadIdx.y * blockDim.x + threadIdx.x] = 0.f;
	}

	__syncthreads();

	if (threadIdx.x >= padding && threadIdx.x < blockDim.x - padding &&
		threadIdx.y >= padding && threadIdx.y < blockDim.y - padding &&
		gx < width && gy < height)
	{
		float average = 0.f;
		int base = -padding;

		for (int i = 0; i < blurSize; ++i)
		{
			for (int j = 0; j < blurSize; ++j)
			{
				average += s_ssaoFactors[(threadIdx.y + base + i) * blockDim.x + (threadIdx.x + base + j)];
			}
		}

		fragmentBuffer[gy * width + gx].ssaoFactor = average / static_cast<float>(blurSize * blurSize);
	}
}

/**
 * Compute occlusion values for each pixel
 */
__global__ void computeSSAO(int width, int height,
	glm::mat4 proj,
	int NoiseTexSize1D, const glm::vec3 *noiseTex,
	float sampleKernelRadius, int numSamples, const glm::vec3 *samples,
	Fragment *fragmentBuffer)
{
	int x = blockIdx.x * blockDim.x + threadIdx.x;
	int y = blockIdx.y * blockDim.y + threadIdx.y;
	int index = x + (y * width);

	if (x < width && y < height)
	{
		Fragment &frag = fragmentBuffer[index];
		glm::vec3 eyePos = frag.eyePos;
		glm::vec3 eyeNrm = frag.eyeNor;
		glm::vec3 right = noiseTex[(x & (NoiseTexSize1D - 1)) + NoiseTexSize1D * (y & (NoiseTexSize1D - 1))];
		glm::mat3 tbn = coordinateSystemZFromZX(eyeNrm, right);

		float occlusion = 0.f;
		const float deepestDepth = -FLT_MAX * .5f; // the camera is looking into -z

		for (int i = 0; i < numSamples; ++i)
		{
			// transform the sample into eye space
			glm::vec3 sample = tbn * samples[i];
			sample = eyePos + sampleKernelRadius * sample;

			// project the sample onto screen space
			glm::vec4 ss = proj * glm::vec4(sample, 1.0);
			ss.x = (ss.x / ss.w * .5f + .5f) * width;
			ss.y = (ss.y / ss.w * .5f + .5f) * height;

			// get pixel depth at sample postion
			// depth value needs to be linear for the range check to actually make sense
			int sx = static_cast<int>(ss.x + .5f);
			int sy = static_cast<int>(ss.y + .5f);
			bool isNotValid = sx < 0 || sx >= width || sy < 0 || sy >= height || !fragmentBuffer[sy * width + sx].shouldShade;
			float sampleDepth = isNotValid ? deepestDepth : fragmentBuffer[sy * width + sx].eyePos.z;
			float rangeCheck = fabs(eyePos.z - sampleDepth) < sampleKernelRadius ? 1.f : 0.f;
			occlusion += ((sampleDepth > sample.z) ? 1.f : 0.f) * rangeCheck;
		}

		frag.ssaoFactor = 1.f - occlusion / static_cast<float>(numSamples);
	}
}

/**
 * Generate samples and noise texture on CPU.
 * Copy results into GPU buffers.
 */
void ssaoInit()
{
	auto seed = std::chrono::high_resolution_clock::now().time_since_epoch().count();
	auto u01 = std::bind(std::uniform_real_distribution<float>(0.f, 1.f), std::mt19937(seed));
	auto u_11 = std::bind(std::uniform_real_distribution<float>(-1.f, 1.f), std::mt19937(seed));

	std::vector<glm::vec3> samples(numSamples);
	for (int i = 0; i < numSamples; ++i)
	{
		glm::vec3 s(u_11(), u_11(), u01());
		s = glm::normalize(s);
		float scale = static_cast<float>(i) / static_cast<float>(numSamples);
		scale *= scale;
		scale = (1.f - scale) * .1f + scale;
		s *= scale;
		samples[i] = s;
	}

	int noiseTexSize2D = noiseTexSize1D * noiseTexSize1D;
	std::vector<glm::vec3> noiseTex(noiseTexSize2D);
	for (int i = 0; i < noiseTexSize2D; ++i)
	{
		glm::vec3 x(u_11(), u_11(), 0.f);
		x = glm::normalize(x);
		noiseTex[i] = x;
	}

	cudaFree(dev_samples);
	cudaMalloc(&dev_samples, numSamples * sizeof(glm::vec3));
	cudaMemcpy(dev_samples, samples.data(), numSamples * sizeof(glm::vec3), cudaMemcpyHostToDevice);

	cudaFree(dev_noiseTex);
	cudaMalloc(&dev_noiseTex, noiseTexSize2D * sizeof(glm::vec3));
	cudaMemcpy(dev_noiseTex, noiseTex.data(), noiseTexSize2D * sizeof(glm::vec3), cudaMemcpyHostToDevice);
}

/**
 * Called once at the beginning of the program to allocate memory.
 */
void rasterizeInit(int w, int h) {
    width = w;
    height = h;
	cudaFree(dev_fragmentBuffer);
	cudaMalloc(&dev_fragmentBuffer, width * height * sizeof(Fragment));
	cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
    cudaFree(dev_framebuffer);
    cudaMalloc(&dev_framebuffer,   width * height * sizeof(glm::vec3));
    cudaMemset(dev_framebuffer, 0, width * height * sizeof(glm::vec3));
    
	cudaFree(dev_depth);
	cudaMalloc(&dev_depth, width * height * sizeof(float));

	numTilesX = ROUND_UP_DIV(w, TILE_SIZE);
	numTilesY = ROUND_UP_DIV(h, TILE_SIZE);
	int numTiles = numTilesX * numTilesY;
	
	cudaFree(dev_primCounts);
	cudaMalloc(&dev_primCounts, numTiles * sizeof(int));
	cudaFree(dev_tileTriLists);

	ssaoInit();

	checkCUDAError("rasterizeInit");
}

__global__
void initDepth(int w, int h, int * depth)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < w && y < h)
	{
		int index = x + (y * w);
		depth[index] = INT_MAX;
	}
}


/**
* kern function with support for stride to sometimes replace cudaMemcpy
* One thread is responsible for copying one component
*/
__global__ 
void _deviceBufferCopy(int N, BufferByte* dev_dst, const BufferByte* dev_src, int n, int byteStride, int byteOffset, int componentTypeByteSize) {
	
	// Attribute (vec3 position)
	// component (3 * float)
	// byte (4 * byte)

	// id of component
	int i = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (i < N) {
		int count = i / n;
		int offset = i - count * n;	// which component of the attribute

		for (int j = 0; j < componentTypeByteSize; j++) {
			
			dev_dst[count * componentTypeByteSize * n 
				+ offset * componentTypeByteSize 
				+ j]

				= 

			dev_src[byteOffset 
				+ count * (byteStride == 0 ? componentTypeByteSize * n : byteStride) 
				+ offset * componentTypeByteSize 
				+ j];
		}
	}
	

}

__global__
void _nodeMatrixTransform(
	int numVertices,
	VertexAttributePosition* position,
	VertexAttributeNormal* normal,
	glm::mat4 MV, glm::mat3 MV_normal) {

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {
		position[vid] = glm::vec3(MV * glm::vec4(position[vid], 1.0f));
		normal[vid] = glm::normalize(MV_normal * normal[vid]);
	}
}

glm::mat4 getMatrixFromNodeMatrixVector(const tinygltf::Node & n) {
	
	glm::mat4 curMatrix(1.0);

	const std::vector<double> &m = n.matrix;
	if (m.size() > 0) {
		// matrix, copy it

		for (int i = 0; i < 4; i++) {
			for (int j = 0; j < 4; j++) {
				curMatrix[i][j] = (float)m.at(4 * i + j);
			}
		}
	} else {
		// no matrix, use rotation, scale, translation

		if (n.translation.size() > 0) {
			curMatrix[3][0] = n.translation[0];
			curMatrix[3][1] = n.translation[1];
			curMatrix[3][2] = n.translation[2];
		}

		if (n.rotation.size() > 0) {
			glm::mat4 R;
			glm::quat q;
			q[0] = n.rotation[0];
			q[1] = n.rotation[1];
			q[2] = n.rotation[2];

			R = glm::mat4_cast(q);
			curMatrix = curMatrix * R;
		}

		if (n.scale.size() > 0) {
			curMatrix = curMatrix * glm::scale(glm::vec3(n.scale[0], n.scale[1], n.scale[2]));
		}
	}

	return curMatrix;
}

void traverseNode (
	std::map<std::string, glm::mat4> & n2m,
	const tinygltf::Scene & scene,
	const std::string & nodeString,
	const glm::mat4 & parentMatrix
	) 
{
	const tinygltf::Node & n = scene.nodes.at(nodeString);
	glm::mat4 M = parentMatrix * getMatrixFromNodeMatrixVector(n);
	n2m.insert(std::pair<std::string, glm::mat4>(nodeString, M));

	auto it = n.children.begin();
	auto itEnd = n.children.end();

	for (; it != itEnd; ++it) {
		traverseNode(n2m, scene, *it, M);
	}
}

void rasterizeSetBuffers(const tinygltf::Scene & scene) {

	totalNumPrimitives = 0;

	std::map<std::string, BufferByte*> bufferViewDevPointers;

	// 1. copy all `bufferViews` to device memory
	{
		std::map<std::string, tinygltf::BufferView>::const_iterator it(
			scene.bufferViews.begin());
		std::map<std::string, tinygltf::BufferView>::const_iterator itEnd(
			scene.bufferViews.end());

		for (; it != itEnd; it++) {
			const std::string key = it->first;
			const tinygltf::BufferView &bufferView = it->second;
			if (bufferView.target == 0) {
				continue; // Unsupported bufferView.
			}

			const tinygltf::Buffer &buffer = scene.buffers.at(bufferView.buffer);

			BufferByte* dev_bufferView;
			cudaMalloc(&dev_bufferView, bufferView.byteLength);
			cudaMemcpy(dev_bufferView, &buffer.data.front() + bufferView.byteOffset, bufferView.byteLength, cudaMemcpyHostToDevice);

			checkCUDAError("Set BufferView Device Mem");

			bufferViewDevPointers.insert(std::make_pair(key, dev_bufferView));

		}
	}



	// 2. for each mesh: 
	//		for each primitive: 
	//			build device buffer of indices, materail, and each attributes
	//			and store these pointers in a map
	{

		std::map<std::string, glm::mat4> nodeString2Matrix;
		auto rootNodeNamesList = scene.scenes.at(scene.defaultScene);

		{
			auto it = rootNodeNamesList.begin();
			auto itEnd = rootNodeNamesList.end();
			for (; it != itEnd; ++it) {
				traverseNode(nodeString2Matrix, scene, *it, glm::mat4(1.0f));
			}
		}


		// parse through node to access mesh

		auto itNode = nodeString2Matrix.begin();
		auto itEndNode = nodeString2Matrix.end();
		for (; itNode != itEndNode; ++itNode) {

			const tinygltf::Node & N = scene.nodes.at(itNode->first);
			const glm::mat4 & matrix = itNode->second;
			const glm::mat3 & matrixNormal = glm::transpose(glm::inverse(glm::mat3(matrix)));

			auto itMeshName = N.meshes.begin();
			auto itEndMeshName = N.meshes.end();

			for (; itMeshName != itEndMeshName; ++itMeshName)
			{
				const tinygltf::Mesh & mesh = scene.meshes.at(*itMeshName);

				auto res = mesh2PrimitivesMap.insert(std::pair<std::string, std::vector<PrimitiveDevBufPointers>>(mesh.name, std::vector<PrimitiveDevBufPointers>()));
				std::vector<PrimitiveDevBufPointers> & primitiveVector = (res.first)->second;

				// for each primitive
				for (size_t i = 0; i < mesh.primitives.size(); i++)
				{
					const tinygltf::Primitive &primitive = mesh.primitives[i];

					if (primitive.indices.empty())
						return;

					// TODO: add new attributes for your PrimitiveDevBufPointers when you add new attributes
					VertexIndex* dev_indices = nullptr;
					VertexAttributePosition* dev_position = nullptr;
					VertexAttributeNormal* dev_normal = nullptr;
					VertexAttributeTexcoord* dev_texcoord0 = nullptr;

					// ----------Indices-------------

					const tinygltf::Accessor &indexAccessor = scene.accessors.at(primitive.indices);
					const tinygltf::BufferView &bufferView = scene.bufferViews.at(indexAccessor.bufferView);
					BufferByte* dev_bufferView = bufferViewDevPointers.at(indexAccessor.bufferView);

					// assume type is SCALAR for indices
					int n = 1;
					int numIndices = indexAccessor.count;
					int componentTypeByteSize = sizeof(VertexIndex);
					int byteLength = numIndices * n * componentTypeByteSize;

					dim3 numThreadsPerBlock(128);
					dim3 numBlocks((numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					cudaMalloc(&dev_indices, byteLength);
					_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
						numIndices,
						(BufferByte*)dev_indices,
						dev_bufferView,
						n,
						indexAccessor.byteStride,
						indexAccessor.byteOffset,
						componentTypeByteSize);


					checkCUDAError("Set Index Buffer");


					// ---------Primitive Info-------

					// Warning: LINE_STRIP is not supported in tinygltfloader
					int numPrimitives;
					PrimitiveType primitiveType;
					switch (primitive.mode) {
					case TINYGLTF_MODE_TRIANGLES:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices / 3;
						break;
					case TINYGLTF_MODE_TRIANGLE_STRIP:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_TRIANGLE_FAN:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_LINE:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices / 2;
						break;
					case TINYGLTF_MODE_LINE_LOOP:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices + 1;
						break;
					case TINYGLTF_MODE_POINTS:
						primitiveType = PrimitiveType::Point;
						numPrimitives = numIndices;
						break;
					default:
						// output error
						break;
					};


					// ----------Attributes-------------

					auto it(primitive.attributes.begin());
					auto itEnd(primitive.attributes.end());

					int numVertices = 0;
					// for each attribute
					for (; it != itEnd; it++) {
						const tinygltf::Accessor &accessor = scene.accessors.at(it->second);
						const tinygltf::BufferView &bufferView = scene.bufferViews.at(accessor.bufferView);

						int n = 1;
						if (accessor.type == TINYGLTF_TYPE_SCALAR) {
							n = 1;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC2) {
							n = 2;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC3) {
							n = 3;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC4) {
							n = 4;
						}

						BufferByte * dev_bufferView = bufferViewDevPointers.at(accessor.bufferView);
						BufferByte ** dev_attribute = NULL;

						numVertices = accessor.count;
						int componentTypeByteSize;

						// Note: since the type of our attribute array (dev_position) is static (float32)
						// We assume the glTF model attribute type are 5126(FLOAT) here

						if (it->first.compare("POSITION") == 0) {
							componentTypeByteSize = sizeof(VertexAttributePosition) / n;
							dev_attribute = (BufferByte**)&dev_position;
						}
						else if (it->first.compare("NORMAL") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeNormal) / n;
							dev_attribute = (BufferByte**)&dev_normal;
						}
						else if (it->first.compare("TEXCOORD_0") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeTexcoord) / n;
							dev_attribute = (BufferByte**)&dev_texcoord0;
						}

						std::cout << accessor.bufferView << "  -  " << it->second << "  -  " << it->first << '\n';

						dim3 numThreadsPerBlock(128);
						dim3 numBlocks((n * numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
						int byteLength = numVertices * n * componentTypeByteSize;
						cudaMalloc(dev_attribute, byteLength);

						_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
							n * numVertices,
							*dev_attribute,
							dev_bufferView,
							n,
							accessor.byteStride,
							accessor.byteOffset,
							componentTypeByteSize);

						std::string msg = "Set Attribute Buffer: " + it->first;
						checkCUDAError(msg.c_str());
					}

					// malloc for VertexOut
					VertexOut* dev_vertexOut;
					cudaMalloc(&dev_vertexOut, numVertices * sizeof(VertexOut));
					checkCUDAError("Malloc VertexOut Buffer");

					// ----------Materials-------------

					// You can only worry about this part once you started to 
					// implement textures for your rasterizer
					TextureData* dev_diffuseTex = NULL;
					int diffuseTexWidth = 0, diffuseTexHeight = 0;

					if (!primitive.material.empty())
					{
						const tinygltf::Material &mat = scene.materials.at(primitive.material);
						printf("material.name = %s\n", mat.name.c_str());

						if (mat.values.find("diffuse") != mat.values.end()) {
							std::string diffuseTexName = mat.values.at("diffuse").string_value;
							if (scene.textures.find(diffuseTexName) != scene.textures.end()) {
								const tinygltf::Texture &tex = scene.textures.at(diffuseTexName);
								if (scene.images.find(tex.source) != scene.images.end()) {
									const tinygltf::Image &image = scene.images.at(tex.source);

									size_t s = image.image.size() * sizeof(TextureData);
									cudaMalloc(&dev_diffuseTex, s);
									cudaMemcpy(dev_diffuseTex, &image.image.at(0), s, cudaMemcpyHostToDevice);
									
									// TODO: store the image size to your PrimitiveDevBufPointers
									diffuseTexWidth = image.width;
									diffuseTexHeight = image.height;

									checkCUDAError("Set Texture Image data");
								}
							}
						}

						// TODO: write your code for other materails
						// You may have to take a look at tinygltfloader
						// You can also use the above code loading diffuse material as a start point 
					}


					// ---------Node hierarchy transform--------
					cudaDeviceSynchronize();
					
					dim3 numBlocksNodeTransform((numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					_nodeMatrixTransform << <numBlocksNodeTransform, numThreadsPerBlock >> > (
						numVertices,
						dev_position,
						dev_normal,
						matrix,
						matrixNormal);

					checkCUDAError("Node hierarchy transformation");

					// at the end of the for loop of primitive
					// push dev pointers to map
					primitiveVector.push_back(PrimitiveDevBufPointers{
						primitive.mode,
						primitiveType,
						numPrimitives,
						numIndices,
						numVertices,

						dev_indices,
						dev_position,
						dev_normal,
						dev_texcoord0,

						diffuseTexWidth,
						diffuseTexHeight,
						dev_diffuseTex,

						dev_vertexOut	//VertexOut
					});

					totalNumPrimitives += numPrimitives;

				} // for each primitive

			} // for each mesh

		} // for each node

	}
	

	// 3. Malloc for dev_primitives
	{
		cudaMalloc(&dev_primitives, totalNumPrimitives * sizeof(Primitive));
		int numTiles = numTilesX * numTilesY;
		if (totalNumPrimitives > TRI_LIST_SCALE_THRESHOLD)
		{
			triListSize = static_cast<int>(TILE_TRI_LIST_SCALE * totalNumPrimitives);
		}
		else
		{
			triListSize = totalNumPrimitives;
		}
		cudaMalloc(&dev_tileTriLists, numTiles * triListSize * sizeof(int));
	}
	

	// Finally, cudaFree raw dev_bufferViews
	{

		std::map<std::string, BufferByte*>::const_iterator it(bufferViewDevPointers.begin());
		std::map<std::string, BufferByte*>::const_iterator itEnd(bufferViewDevPointers.end());
			
			//bufferViewDevPointers

		for (; it != itEnd; it++) {
			cudaFree(it->second);
		}

		checkCUDAError("Free BufferView Device Mem");
	}


}



__global__ 
void _vertexTransformAndAssembly(
	int numVertices, 
	PrimitiveDevBufPointers primitive, 
	glm::mat4 MVP, glm::mat4 MV, glm::mat3 MV_normal, 
	int width, int height)
{
	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {

		// TODO: Apply vertex transformation here
		// Multiply the MVP matrix for each vertex position, this will transform everything into clipping space
		// Then divide the pos by its w element to transform into NDC space
		// Finally transform x and y to viewport space
		glm::vec3 pos = primitive.dev_position[vid];
		glm::vec3 nrm = primitive.dev_normal[vid];

		glm::vec3 eyePos = glm::vec3(MV * glm::vec4(pos, 1.f));
		glm::vec3 eyeNor = glm::normalize(MV_normal * nrm);

		glm::vec4 clipPos = MVP * glm::vec4(pos, 1.f);
		glm::vec4 outPos(
			(clipPos.x / clipPos.w + 1.f) * .5f * static_cast<float>(width),
			(clipPos.y / clipPos.w + 1.f) * .5f * static_cast<float>(height),
			clipPos.z,
			clipPos.w);

		// TODO: Apply vertex assembly here
		// Assemble all attribute arraies into the primitive array
		primitive.dev_verticesOut[vid].pos = outPos; // x, y in screen space. z in NDC
		primitive.dev_verticesOut[vid].eyePos = eyePos;
		primitive.dev_verticesOut[vid].eyeNor = eyeNor;
		if (primitive.dev_texcoord0)
		{
			primitive.dev_verticesOut[vid].texcoord0 = primitive.dev_texcoord0[vid];
		}
		if (primitive.dev_diffuseTex)
		{
			primitive.dev_verticesOut[vid].dev_diffuseTex = primitive.dev_diffuseTex;
		}
		primitive.dev_verticesOut[vid].diffuseTexWidth = primitive.diffuseTexWidth;
		primitive.dev_verticesOut[vid].diffuseTexHeight = primitive.diffuseTexHeight;
	}
}



static int curPrimitiveBeginId = 0;

__global__ 
void _primitiveAssembly(int numIndices, int curPrimitiveBeginId, Primitive* dev_primitives, PrimitiveDevBufPointers primitive) {

	// index id
	int iid = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (iid < numIndices) {

		// TODO: uncomment the following code for a start
		// This is primitive assembly for triangles

		int pid;	// id for cur primitives vector
		if (primitive.primitiveMode == TINYGLTF_MODE_TRIANGLES)
		{
			pid = iid / (int)primitive.primitiveType;
			dev_primitives[pid + curPrimitiveBeginId].v[iid % (int)primitive.primitiveType]
				= primitive.dev_verticesOut[primitive.dev_indices[iid]];
		}


		// TODO: other primitive types (point, line)
	}
	
}


__global__ void _rasterize(int numPrims, int width, int height, const Primitive *primitives, int *depthBuff, Fragment *fragments)
{
	int pid = blockDim.x * blockIdx.x + threadIdx.x;

	if (pid < numPrims)
	{
		const Primitive &prim = primitives[pid];

		glm::vec3 tri[3] =
		{
			glm::vec3(prim.v[0].pos),
			glm::vec3(prim.v[1].pos),
			glm::vec3(prim.v[2].pos)
		};

		if (!isFrontFacing(tri))
		{
			return;
		}

		AABB bbox = getAABBForTriangle(tri);

		int xmin = glm::min(width - 1, glm::max(0, static_cast<int>(bbox.min.x)));
		int xmax = glm::min(width - 1, glm::max(0, static_cast<int>(bbox.max.x)));
		int ymin = glm::min(height - 1, glm::max(0, static_cast<int>(bbox.min.y)));
		int ymax = glm::min(height - 1, glm::max(0, static_cast<int>(bbox.max.y)));

		for (int x = xmin; x <= xmax; ++x)
		{
			for (int y = ymin; y <= ymax; ++y)
			{
				glm::vec2 pix(x, y);
				glm::vec3 abc = calculateBarycentricCoordinate(tri, pix);

				if (isBarycentricCoordInBounds(abc))
				{
					// TODO
					// write fragment (x, y) if it passes depth test
					// For persepctive correct interpolation, we need to interpolate the reciprocal of
					// vertex depths before doing perspective division in order to obtain the correct
					// depth values. Interpolation of other vertex attributes also need special treatment
					// rather than iterpolating using screen-space Barycentric coordinates directly.
					// clipPos.w should be used instead of clipPos.z because, clipPos.w is the vertex's
					// depth in eye space multiplied by a constant. When it is used for interpolation,
					// the constant will eventually being cancelled out. Nonetheless, clipPos.z equals
					// the vertex's depth in eye space times a constant and then offset by -1. As a
					// result, it is not porpotional to the actual depth value of the vertex.
					int idx = y * width + x;
					float oneOverZ0 = 1.f / prim.v[0].pos.w;
					float oneOverZ1 = 1.f / prim.v[1].pos.w;
					float oneOverZ2 = 1.f / prim.v[2].pos.w;
					float oneOverPixDepth = getFloatAtCoordinate(abc, oneOverZ0, oneOverZ1, oneOverZ2);
					float pixDepth = 1.f / oneOverPixDepth;
					float pixDepthNDC = getFloatAtCoordinate(abc, tri[0].z * oneOverZ0, tri[1].z * oneOverZ1, tri[2].z * oneOverZ2);

					if (pixDepthNDC > -1.f && pixDepthNDC < 1.f)
					{
						int iPixDepth = static_cast<int>(pixDepthNDC * INT_MAX);
						int iOldDepth = atomicMin(&depthBuff[idx], iPixDepth);

						if (iPixDepth < iOldDepth)
						{
							//fragments[idx].color = glm::vec3(1.f, 1.f, 1.f);
							fragments[idx].eyePos =
								getVec3AtCoordinate(abc, prim.v[0].eyePos * oneOverZ0, prim.v[1].eyePos * oneOverZ1, prim.v[2].eyePos * oneOverZ2) * pixDepth;
							fragments[idx].eyeNor = glm::normalize(
								getVec3AtCoordinate(abc, prim.v[0].eyeNor * oneOverZ0, prim.v[1].eyeNor * oneOverZ1, prim.v[2].eyeNor * oneOverZ2) * pixDepth);
							if (prim.v[0].dev_diffuseTex)
							{
								fragments[idx].texcoord0 =
									getVec2AtCoordinate(abc, prim.v[0].texcoord0 * oneOverZ0, prim.v[1].texcoord0 * oneOverZ1, prim.v[2].texcoord0 * oneOverZ2) * pixDepth;
								fragments[idx].dev_diffuseTex =
									prim.v[0].dev_diffuseTex;
								fragments[idx].diffuseTexWidth = prim.v[0].diffuseTexWidth;
								fragments[idx].diffuseTexHeight = prim.v[0].diffuseTexHeight;
							}
							fragments[idx].shouldShade = 1;
						}
					}
				}
			}
		}
	}
}


__global__ void fillTileTriLists(int numPrims, int numTilesX, int numTilesY, int triListSize, const Primitive *primitives, int *primCounts, int *tileTriLists)
{
	int pidx = blockDim.x * blockIdx.x + threadIdx.x;

	if (pidx < numPrims)
	{
		const Primitive &prim = primitives[pidx];
		glm::vec3 tri[3] =
		{
			glm::vec3(prim.v[0].pos),
			glm::vec3(prim.v[1].pos),
			glm::vec3(prim.v[2].pos)
		};

		if (!isFrontFacing(tri))
		{
			return;
		}

		AABB bbox = getAABBForTriangle(tri);

		int tileXMin = glm::max(0, static_cast<int>(floorf((bbox.min.x + .5f) / TILE_SIZE)));
		int tileXMax = glm::min(numTilesX - 1, static_cast<int>(floorf((bbox.max.x + .5f) / TILE_SIZE)));
		int tileYMin = glm::max(0, static_cast<int>(floorf((bbox.min.y + .5f) / TILE_SIZE)));
		int tileYMax = glm::min(numTilesY - 1, static_cast<int>(floorf((bbox.max.y + .5f) / TILE_SIZE)));

		for (int y = tileYMin; y <= tileYMax; ++y)
		{
			for (int x = tileXMin; x <= tileXMax; ++x)
			{
				AABB tileBound =
				{
					{ float(x * TILE_SIZE) - .5f, float(y * TILE_SIZE) - .5f, 0.f },
					{ float((x + 1) * TILE_SIZE) - .5f, float((y + 1) * TILE_SIZE) - .5f, 0.f },
				};

				if (triAABBIntersect(tileBound, tri))
				{
					int tidx = y * numTilesX + x;
					int offset = atomicAdd(&primCounts[tidx], 1);
					tileTriLists[tidx * triListSize + offset] = pidx;
				}
			}
		}
	}
}


__global__ void tileBasedRasterize(
	int numPrims, int width, int height, int numTilesX, int numTilesY, int triListSize,
	const Primitive *primitives, int *primCounts, int *tileTriLists,
	float *depthBuff, Fragment *fragments)
{
	float l_depthBuff = 1.f;
	Fragment l_fragment{};

	int pixIdxX = blockIdx.x * TILE_SIZE + threadIdx.x;
	int pixIdxY = blockIdx.y * TILE_SIZE + threadIdx.y;
	int pixIdx = pixIdxY * width + pixIdxX;
	int tileIdx = blockIdx.y * numTilesX + blockIdx.x;
	int numTris = primCounts[tileIdx];
	int *triList = tileTriLists + triListSize * tileIdx;

	if (pixIdxX >= width || pixIdxY >= height)
	{
		return;
	}

	for (int i = 0; i < numTris; ++i)
	{
		const Primitive &prim = primitives[triList[i]];
		glm::vec3 tri[3] =
		{
			glm::vec3(prim.v[0].pos),
			glm::vec3(prim.v[1].pos),
			glm::vec3(prim.v[2].pos)
		};
		glm::vec3 abc = calculateBarycentricCoordinate(tri, glm::vec2(pixIdxX, pixIdxY));

		if (isBarycentricCoordInBounds(abc))
		{
			float oneOverZ0 = 1.f / prim.v[0].pos.w;
			float oneOverZ1 = 1.f / prim.v[1].pos.w;
			float oneOverZ2 = 1.f / prim.v[2].pos.w;
			float oneOverPixDepth = getFloatAtCoordinate(abc, oneOverZ0, oneOverZ1, oneOverZ2);
			float pixDepth = 1.f / oneOverPixDepth;
			float pixDepthNDC = getFloatAtCoordinate(abc, tri[0].z * oneOverZ0, tri[1].z * oneOverZ1, tri[2].z * oneOverZ2);

			if (pixDepthNDC > -1.f && pixDepthNDC < l_depthBuff)
			{
				l_depthBuff = pixDepthNDC;
				l_fragment.eyePos =
					getVec3AtCoordinate(abc, prim.v[0].eyePos * oneOverZ0, prim.v[1].eyePos * oneOverZ1, prim.v[2].eyePos * oneOverZ2) * pixDepth;
				l_fragment.eyeNor = glm::normalize(
					getVec3AtCoordinate(abc, prim.v[0].eyeNor * oneOverZ0, prim.v[1].eyeNor * oneOverZ1, prim.v[2].eyeNor * oneOverZ2) * pixDepth);
				l_fragment.texcoord0 =
					getVec2AtCoordinate(abc, prim.v[0].texcoord0 * oneOverZ0, prim.v[1].texcoord0 * oneOverZ1, prim.v[2].texcoord0 * oneOverZ2) * pixDepth;
				l_fragment.dev_diffuseTex =
					prim.v[0].dev_diffuseTex;
				l_fragment.diffuseTexWidth = prim.v[0].diffuseTexWidth;
				l_fragment.diffuseTexHeight = prim.v[0].diffuseTexHeight;
				l_fragment.shouldShade = true;
			}
		}
	}

	depthBuff[pixIdx] = l_depthBuff;
	fragments[pixIdx] = l_fragment;
}


/**
 * Perform rasterization.
 */
void rasterize(uchar4 *pbo, const glm::mat4 & MVP, const glm::mat4 & MV, const glm::mat3 MV_normal, const glm::mat4 &P) {
    int sideLength2d = 8;
    dim3 blockSize2d(sideLength2d, sideLength2d);
    dim3 blockCount2d((width  - 1) / blockSize2d.x + 1,
		(height - 1) / blockSize2d.y + 1);

	// Execute your rasterization pipeline here
	// (See README for rasterization pipeline outline.)

	// Vertex Process & primitive assembly
	{
		curPrimitiveBeginId = 0;
		dim3 numThreadsPerBlock(128);

		auto it = mesh2PrimitivesMap.begin();
		auto itEnd = mesh2PrimitivesMap.end();

		for (; it != itEnd; ++it) {
			auto p = (it->second).begin();	// each primitive
			auto pEnd = (it->second).end();
			for (; p != pEnd; ++p) {
				dim3 numBlocksForVertices((p->numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
				dim3 numBlocksForIndices((p->numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);

				_vertexTransformAndAssembly<<<numBlocksForVertices, numThreadsPerBlock>>>(p->numVertices, *p, MVP, MV, MV_normal, width, height);
				checkCUDAError("Vertex Processing");
				cudaDeviceSynchronize();
				_primitiveAssembly<<<numBlocksForIndices, numThreadsPerBlock>>>(
					p->numIndices, 
					curPrimitiveBeginId, 
					dev_primitives, 
					*p);
				checkCUDAError("Primitive Assembly");

				curPrimitiveBeginId += p->numPrimitives;
			}
		}

		checkCUDAError("Vertex Processing and Primitive Assembly");
	}

	// TODO: rasterize
	int numTiles = numTilesX * numTilesY;
	cudaMemset(dev_primCounts, 0, numTiles * sizeof(int));

	const int blockSize1d = 128;
	int numBlocks = (totalNumPrimitives + blockSize1d - 1) / blockSize1d;
	fillTileTriLists<<<numBlocks, blockSize1d>>>(totalNumPrimitives, numTilesX, numTilesY, triListSize, dev_primitives, dev_primCounts, dev_tileTriLists);

	dim3 numBlocks3(numTilesX, numTilesY, 1);
	dim3 blockSize3(TILE_SIZE, TILE_SIZE, 1);
	cudaFuncSetCacheConfig(tileBasedRasterize, cudaFuncCachePreferL1);
	tileBasedRasterize<<<numBlocks3, blockSize3>>>(totalNumPrimitives, width, height, numTilesX, numTilesY, triListSize, dev_primitives, dev_primCounts, dev_tileTriLists, dev_depth, dev_fragmentBuffer);
	checkCUDAError("tileBasedRasterize");

	//cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
	//initDepth<<<blockCount2d, blockSize2d>>>(width, height, dev_depth);
	//_rasterize<<<numBlocks, blockSize1d>>>(totalNumPrimitives, width, height, dev_primitives, dev_depth, dev_fragmentBuffer);

	computeSSAO<<<blockCount2d, blockSize2d>>>(width, height, P, noiseTexSize1D, dev_noiseTex, sampleKernelRadius, numSamples, dev_samples, dev_fragmentBuffer);
	checkCUDAError("computeSSAO");

	int blurSize = noiseTexSize1D;
	int padding = blurSize >> 1;
	dim3 blurBlockSize3(sideLength2d + 2 * padding, sideLength2d + 2 * padding, 1);
	ssaoBlur<<<blockCount2d , blurBlockSize3, blurBlockSize3.x * blurBlockSize3.y * sizeof(float)>>>(width, height, blurSize, dev_fragmentBuffer);
	checkCUDAError("ssaoBlur");

    // Copy depthbuffer colors into framebuffer
	cudaMemset(dev_framebuffer, 0, width * height * sizeof(glm::vec3));
	render<<<blockCount2d, blockSize2d>>>(width, height, dev_fragmentBuffer, dev_framebuffer);
	checkCUDAError("fragment shader");
    // Copy framebuffer into OpenGL buffer for OpenGL previewing
    sendImageToPBO<<<blockCount2d, blockSize2d>>>(pbo, width, height, dev_framebuffer);
    checkCUDAError("copy render result to pbo");
}

/**
 * Called once at the end of the program to free CUDA memory.
 */
void rasterizeFree() {

    // deconstruct primitives attribute/indices device buffer

	auto it(mesh2PrimitivesMap.begin());
	auto itEnd(mesh2PrimitivesMap.end());
	for (; it != itEnd; ++it) {
		for (auto p = it->second.begin(); p != it->second.end(); ++p) {
			cudaFree(p->dev_indices);
			cudaFree(p->dev_position);
			cudaFree(p->dev_normal);
			cudaFree(p->dev_texcoord0);
			cudaFree(p->dev_diffuseTex);

			cudaFree(p->dev_verticesOut);

			
			//TODO: release other attributes and materials
		}
	}

	////////////

    cudaFree(dev_primitives);
    dev_primitives = NULL;

	cudaFree(dev_fragmentBuffer);
	dev_fragmentBuffer = NULL;

    cudaFree(dev_framebuffer);
    dev_framebuffer = NULL;

	cudaFree(dev_depth);
	dev_depth = NULL;

	cudaFree(dev_primCounts);
	dev_primCounts = nullptr;

	cudaFree(dev_tileTriLists);
	dev_tileTriLists = nullptr;

	cudaFree(dev_samples);
	dev_samples = nullptr;

	cudaFree(dev_noiseTex);
	dev_noiseTex = nullptr;

    checkCUDAError("rasterize Free");
}
