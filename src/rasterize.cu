/**
 * @file      rasterize.cu
 * @brief     CUDA-accelerated rasterization pipeline.
 * @authors   Skeleton code: Yining Karl Li, Kai Ninomiya, Shuai Shao (Shrek)
 * @date      2012-2016
 * @copyright University of Pennsylvania & STUDENT
 */

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
#include <chrono>

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
		 glm::vec3 col; //color of the vertex
		 glm::vec2 texcoord0;
		 TextureData* dev_diffuseTex = NULL;
		 int texWidth, texHeight;
		// ...
	};

	struct Primitive {
		PrimitiveType primitiveType = Triangle;	// C++ 11 init
		VertexOut v[3];
	};

	struct Fragment {
		glm::vec3 color;

		// TODO: add new attributes to your Fragment
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		glm::vec3 eyePos;	// eye space position used for shading
		glm::vec3 eyeNor;
		// VertexAttributeTexcoord texcoord0;
		// TextureData* dev_diffuseTex;
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
		TextureData* dev_diffuseTex;
		int diffuseTexWidth;
		int diffuseTexHeight;
		// TextureData* dev_specularTex;
		// TextureData* dev_normalTex;
		// ...

		// Vertex Out, vertex used for rasterization, this is changing every frame
		VertexOut* dev_verticesOut;

		// TODO: add more attributes when needed
	};

}

//***************Performance Analysis Timer******************//
PerformanceTimer& timer()
{
	static PerformanceTimer timer;
	return timer;
}
//***************Performance Analysis Timer******************//

static std::map<std::string, std::vector<PrimitiveDevBufPointers>> mesh2PrimitivesMap;


static int width = 0;
static int height = 0;

static int totalNumPrimitives = 0;
static Primitive *dev_primitives = NULL;
static Fragment *dev_fragmentBuffer = NULL;
static glm::vec3 *dev_framebuffer = NULL;

static int * dev_depth = NULL;	// you might need this buffer when doing depth test

static glm::vec3 sceneLightDir = glm::normalize(glm::vec3(0, -1, -1));
static float lightIntensity = 2.0f;


/**
 * Kernel that writes the image to the OpenGL PBO directly.
 */
__global__ 
void sendImageToPBO(uchar4 *pbo, int w, int h, glm::vec3 *image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
        glm::vec3 color;
        color.x = glm::clamp(image[index].x, 0.0f, 1.0f) * 255.0;
        color.y = glm::clamp(image[index].y, 0.0f, 1.0f) * 255.0;
        color.z = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

/** 
* Writes fragment colors to the framebuffer
*/
__global__
void render(int w, int h, Fragment *fragmentBuffer, glm::vec3 *framebuffer, glm::vec3 lightDir, float lightIntensity, PrimitiveType mode) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
		if (mode == Line || mode == Point) {
			framebuffer[index] = fragmentBuffer[index].color;
		}
		else {
			//Lambert
			float lambertTerm = glm::dot(fragmentBuffer[index].eyeNor, lightDir);
			if (lambertTerm <= 0) {
				lambertTerm = 0.2;
			}
			else if (lambertTerm > 1) {
				lambertTerm = 1;
			}
			framebuffer[index] = glm::clamp(lambertTerm*lightIntensity*fragmentBuffer[index].color, glm::vec3(0), glm::vec3(1));
			// TODO: add your fragment shader code here
		}
    }
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
	cudaMalloc(&dev_depth, width * height * sizeof(int));

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

			for (; itMeshName != itEndMeshName; ++itMeshName) {

				const tinygltf::Mesh & mesh = scene.meshes.at(*itMeshName);

				auto res = mesh2PrimitivesMap.insert(std::pair<std::string, std::vector<PrimitiveDevBufPointers>>(mesh.name, std::vector<PrimitiveDevBufPointers>()));
				std::vector<PrimitiveDevBufPointers> & primitiveVector = (res.first)->second;

				// for each primitive
				for (size_t i = 0; i < mesh.primitives.size(); i++) {
					const tinygltf::Primitive &primitive = mesh.primitives[i];

					if (primitive.indices.empty())
						return;

					// TODO: add new attributes for your PrimitiveDevBufPointers when you add new attributes
					VertexIndex* dev_indices = NULL;
					VertexAttributePosition* dev_position = NULL;
					VertexAttributeNormal* dev_normal = NULL;
					VertexAttributeTexcoord* dev_texcoord0 = NULL;

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
					int diffuseTexWidth = 0;
					int diffuseTexHeight = 0;
					if (!primitive.material.empty()) {
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

						dev_diffuseTex,
						diffuseTexWidth,
						diffuseTexHeight,

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
	int width, int height, float scale) {

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {

		// TODO: Apply vertex transformation here
		// Multiply the MVP matrix for each vertex position, this will transform everything into clipping space
		// Then divide the pos by its w element to transform into NDC space
		// Finally transform x and y to viewport space
		glm::vec4 modelSpacePos = glm::vec4(primitive.dev_position[vid].x*scale,
											primitive.dev_position[vid].y*scale,
											primitive.dev_position[vid].z*scale, 1);
		glm::vec3 eyeSpacePos = multiplyMV(MV, modelSpacePos);
		glm::vec4 projectionPos = MVP * modelSpacePos;
		glm::vec3 ndcPos = glm::vec3(projectionPos.x / projectionPos.w,
										projectionPos.y / projectionPos.w,
										projectionPos.z / projectionPos.w);

		glm::vec2 screenPos = glm::vec2((ndcPos.x + 1)* (width*1.0f / 2), (1 - ndcPos.y)* (height*1.0f / 2));
		glm::vec3 modelSpaceNor = glm::vec3(primitive.dev_normal[vid]);
		glm::vec3 eyeSpaceNormal = glm::normalize(MV_normal * modelSpaceNor);

		// TODO: Apply vertex assembly here
		// Assemble all attribute arraies into the primitive array
		primitive.dev_verticesOut[vid].pos = glm::vec4(screenPos.x, screenPos.y, eyeSpacePos.z,1);
		primitive.dev_verticesOut[vid].eyePos = eyeSpacePos;
		primitive.dev_verticesOut[vid].eyeNor = eyeSpaceNormal;
		
		//Read color from texture file
		if (primitive.dev_diffuseTex != NULL) {
			primitive.dev_verticesOut[vid].dev_diffuseTex = primitive.dev_diffuseTex;
			primitive.dev_verticesOut[vid].texcoord0 = primitive.dev_texcoord0[vid];
			primitive.dev_verticesOut[vid].texWidth = primitive.diffuseTexWidth;
			primitive.dev_verticesOut[vid].texHeight = primitive.diffuseTexHeight;
			primitive.dev_verticesOut[vid].col = glm::vec3(0.6);
		}
		else {
			primitive.dev_verticesOut[vid].col = glm::vec3(0.6);
			//Test for color interpolation
			/*if (vid % 3 == 0) {
				primitive.dev_verticesOut[vid].col = glm::vec3(vid*1.0 / numVertices, 0, 0);
			}
			if (vid % 3 == 1) {
				primitive.dev_verticesOut[vid].col = glm::vec3(0, vid*1.0 / numVertices, 0);
			}
			if (vid % 3 == 2) {
				primitive.dev_verticesOut[vid].col = glm::vec3(0, 0, vid*1.0 / numVertices);
			}*/
		}	
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
		if (primitive.primitiveMode == TINYGLTF_MODE_TRIANGLES) {
			pid = iid / (int)primitive.primitiveType;
			dev_primitives[pid + curPrimitiveBeginId].v[iid % (int)primitive.primitiveType]
				= primitive.dev_verticesOut[primitive.dev_indices[iid]];
		}


		// TODO: other primitive types (point, line)
	}
	
}

__device__
float getZbyLerp(glm::vec2 newPos, glm::vec3 p1, glm::vec3 p2) {
	float fraction = (newPos.x - p1.x) / (p2.x - p1.x);
	return (1 - fraction)*p1.z + fraction*p2.z;
}

__device__
void rasterizeLine(VertexOut point1, VertexOut point2, Fragment* dev_fragmentBuffer, int* dev_depth, int height, int width) {
	glm::vec3 line[2] = { glm::vec3(point1.pos) , glm::vec3(point2.pos) };
	AABB boundBox = getAABBForLine(line);
	if (boundBox.min.x > width - 1 || boundBox.min.y > height - 1 || boundBox.max.x < 0 || boundBox.max.y < 0) {
		return;
	}
	else {
		boundBox.min.x = boundBox.min.x >= 0 ? boundBox.min.x : 0;
		boundBox.max.x = boundBox.max.x < width ? boundBox.max.x : width-1;
		boundBox.min.y = boundBox.min.y >= 0 ? boundBox.min.y : 0;
		boundBox.max.y = boundBox.max.y < height ? boundBox.max.y : height-1;

		for (int x = boundBox.min.x; x <= boundBox.max.x; x++) {
			for (int y = boundBox.min.y; y <= boundBox.max.y; y ++) {
				if (fabs(glm::dot(glm::normalize(glm::vec3(x - point1.pos.x, y - point1.pos.y, 0)), 
					glm::normalize(glm::vec3(point2.pos.x - x, point2.pos.y - y, 0)))- 1) <0.005) {
					float fragmentDepth = getZbyLerp(glm::vec2(x, y), glm::vec3(point1.pos), glm::vec3(point2.pos));
					int mappedIntDepth = fragmentDepth * 100;
					int fragmentIndex = y*width + x;
					int oldDepth = atomicMin(&dev_depth[fragmentIndex], mappedIntDepth);
					if (oldDepth > mappedIntDepth) {
						dev_fragmentBuffer[fragmentIndex].color = glm::vec3(0.6);
					}
				}
			}
		}
	}
}

__device__
int minimum(int a, int b) {
	return a < b ? a : b;
}

__device__
int maximum(int a, int b) {
	return a > b ? a : b;
}

__device__
void bresenhamLine(int x0, int y0, int x1, int y1, Fragment* dev_fragmentBuffer, int width, int height) {
	//Reference: http://tech-algorithm.com/articles/drawing-line-using-bresenham-algorithm/
	int w = x1 - x0;
	int h = y1 - y0;
	int dx1 = 0, dy1 = 0, dx2 = 0, dy2 = 0;
	if (w<0) dx1 = -1; else if (w>0) dx1 = 1;
	if (h<0) dy1 = -1; else if (h>0) dy1 = 1;
	if (w<0) dx2 = -1; else if (w>0) dx2 = 1;
	int longest = abs(w);
	int shortest = abs(h);
	if (!(longest>shortest)) {
		longest = abs(h);
		shortest = abs(w);
		if (h<0) dy2 = -1; else if (h>0) dy2 = 1;
		dx2 = 0;
	}
	int numerator = longest >> 1;
	for (int i = 0; i <= longest; i++) {
		int fragmentIndex = y0*width + x0;
		dev_fragmentBuffer[fragmentIndex].color = glm::vec3(0.6);
		numerator += shortest;
		if (!(numerator<longest)) {
			numerator -= longest;
			x0 += dx1;
			y0 += dy1;
		}
		else {
			x0 += dx2;
			y0 += dy2;
		}
	}
}

__device__
void rasterizeWireFrame(VertexOut point1, VertexOut point2, Fragment* dev_fragmentBuffer, int* dev_depth, int height, int width) {
	int x0, y0, x1, y1;
	//float z0, z1;
	glm::vec3 color0, color1;

	if (point1.pos.x < point2.pos.x) {
		x0 = maximum(point1.pos.x, 0);
		y0 = point1.pos.y;
		if (y0 < 0) {
			y0 = 0;
		}
		if (y0 > height - 1) {
			y0 = height - 1;
		}
		//z0 = point1.pos.z;
		color0 = point1.col;

		x1 = minimum(point2.pos.x, width - 1);
		y1 = point2.pos.y;
		if (y1 < 0) {
			y1 = 0;
		}
		if (y1 > height - 1) {
			y1 = height - 1;
		}
		//z1 = point2.pos.z;
		color1 = point2.col;

	}
	else {
		x0 = maximum(point2.pos.x, 0);
		y0 = point2.pos.y;
		if (y0 < 0) {
			y0 = 0;
		}
		if (y0 > height - 1) {
			y0 = height - 1;
		}
		//z0 = point2.pos.z;
		color0 = point2.col;
		x1 = minimum(point1.pos.x, width - 1);
		y1 = point1.pos.y;
		if (y1 < 0) {
			y1 = 0;
		}
		if (y1 > height - 1) {
			y1 = height - 1;
		}
		//z1 = point1.pos.z;
		color1 = point1.col;
	}

	//horizontal Line
	if (y0 == y1) {
		for (int x = x0; x <= x1; x++) {
			int fragmentIndex = y0*width + x;
			dev_fragmentBuffer[fragmentIndex].color = glm::vec3(0.6);
		}
	}
	else if (x0 == x1) {
		//verticle Line
		for (int y = y0; y <= y1; y++) {
			int fragmentIndex = y*width + x0;
			dev_fragmentBuffer[fragmentIndex].color = glm::vec3(0.6);
		}
	}
	else {
		bresenhamLine(x0, y0, x1, y1, dev_fragmentBuffer, width, height);
	}
}

__global__
void _rasterizePrimitive(int numOfPrimitives, Primitive* dev_primitives, Fragment* dev_fragmentBuffer,
							int* dev_depth, int height, int width, PrimitiveType mode) {
	int pid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (pid < numOfPrimitives) {
		if (mode == Triangle) {
			//Take out vertices of the triangle
			glm::vec3 p1 = glm::vec3(dev_primitives[pid].v[0].pos);
			glm::vec3 p2 = glm::vec3(dev_primitives[pid].v[1].pos);
			glm::vec3 p3 = glm::vec3(dev_primitives[pid].v[2].pos);
				
			//********************Rasterize Triangle**********************//
			//Get bounding box for the triangle
			glm::vec3 triangle[3] = { p1,p2,p3};
			AABB bound = getAABBForTriangle(triangle);
			bool outofscreen = false;
			if (bound.max.y < 0 || bound.min.y>height - 1 || bound.max.x<0 || bound.min.x>width - 1) {
				//primitive out of screen no need to rasterize;
				outofscreen = true;
			}
			if (!outofscreen) {
				int rowMin = bound.min.y >= 0 ? bound.min.y : 0;
				int rowMax = bound.max.y < height ? bound.max.y : height - 1;
				int colMin = bound.min.x >= 0 ? bound.min.x : 0;
				int colMax = bound.max.x < width ? bound.max.x : width - 1;

				for (int row = rowMin; row <= rowMax; row++) {
					for (int col = colMin; col <= colMax; col++) {
						int fragmentIndex = row*width + col;
						glm::vec2 fragmentCoord = glm::vec2(col, row);
						glm::vec3 baryCentricFragment = calculateBarycentricCoordinate(triangle, fragmentCoord);
						if (isBarycentricCoordInBounds(baryCentricFragment)) {
							//Apply Texture if available						
							//Check with depth buffer
							float fragmentDepth = getZAtCoordinate(baryCentricFragment, triangle);
							int mappedIntDepth = fragmentDepth * 100;
							//change to atomic compare
							int oldDepth = atomicMin(&dev_depth[fragmentIndex], mappedIntDepth);
							if (oldDepth > mappedIntDepth) {
								if (dev_primitives[pid].v[0].dev_diffuseTex != NULL) {
									glm::vec2 texture[3] = { dev_primitives[pid].v[0].texcoord0,
										dev_primitives[pid].v[1].texcoord0,
										dev_primitives[pid].v[2].texcoord0 };
									float depths[3] = { p1.z,p2.z,p3.z};
									float fragmentDepthEyeSpace = getEyeSpaceZAtCoordinate(baryCentricFragment, triangle);
									glm::vec2 fragmentTextureCoord = getTextureAtCoord(baryCentricFragment, texture, depths, fragmentDepthEyeSpace);
									int imageWidth = dev_primitives[pid].v[0].texWidth;
									int imageHeight = dev_primitives[pid].v[0].texHeight;
									int textureIndex = ((int)(fragmentTextureCoord.y*imageHeight))*imageWidth + (int)(fragmentTextureCoord.x*imageWidth);
									float r = dev_primitives[pid].v[0].dev_diffuseTex[textureIndex * 3];
									float g = dev_primitives[pid].v[0].dev_diffuseTex[textureIndex * 3 + 1];
									float b = dev_primitives[pid].v[0].dev_diffuseTex[textureIndex * 3 + 2];
									dev_fragmentBuffer[fragmentIndex].color = glm::vec3(r / 255, g / 255, b / 255);
								}
								else {
									glm::vec3 color[3] = { dev_primitives[pid].v[0].col,
										dev_primitives[pid].v[1].col,
										dev_primitives[pid].v[2].col };
									dev_fragmentBuffer[fragmentIndex].color = getColorAtCoordinate(baryCentricFragment, color);
									//Test Normal
									//dev_fragmentBuffer[fragmentIndex].color = dev_primitives[pid].v[0].eyeNor;
								}
								dev_fragmentBuffer[fragmentIndex].eyeNor = dev_primitives[pid].v[0].eyeNor;
							}

							/*******************No Depth Test*****************/
							//dev_fragmentBuffer[fragmentIndex].color = dev_primitives[pid].v[0].eyeNor;
							//dev_fragmentBuffer[fragmentIndex].color = glm::vec3(1.0f);
							/*******************No Depth Test*****************/
						}
					}
				}
			}			
			//********************Rasterize Triangle**********************//
		}
		if (mode == Point) {
			//*******************Rasterize Point***********************//
			for (int index = 0; index < 3; index++) {
				glm::vec3 p = glm::vec3(dev_primitives[pid].v[index].pos);				
				int startRow = floor(p.y) - 1 > 0 ? floor(p.y) - 1 : 0;
				int endRow = floor(p.y) + 1 < height ? floor(p.y) + 1 : height-1;
				int startCol = floor(p.x) - 1 > 0 ? floor(p.x) - 1 : 0;
				int endCol = floor(p.x) + 1 < width ? floor(p.x) + 1 : width-1;
				float fragmentDepth = p.z;
				int mappedIntDepth = fragmentDepth * 100;
				//Color the surrounding fragments
				for (int x = startCol; x <= endCol; x++) {
					for (int y = startRow; y <= endRow; y++) {
						int fragmentIndex = y*width + x;
						int oldDepth = atomicMin(&dev_depth[fragmentIndex], mappedIntDepth);
						if (oldDepth > mappedIntDepth) {
							dev_fragmentBuffer[fragmentIndex].color = dev_primitives[pid].v[index].col;
						}
					}
				}
			}
			//*******************Rasterize Point***********************//
		}
		if (mode == Line) {
			//*******************Rasterize Line***********************//
			//**** rasterizeWireFrame uses Bresenham algorithm, third party code****//
			rasterizeWireFrame(dev_primitives[pid].v[0], dev_primitives[pid].v[1], dev_fragmentBuffer, dev_depth, height, width);
			rasterizeWireFrame(dev_primitives[pid].v[0], dev_primitives[pid].v[2], dev_fragmentBuffer, dev_depth,height, width);
			rasterizeWireFrame(dev_primitives[pid].v[1], dev_primitives[pid].v[2], dev_fragmentBuffer, dev_depth, height, width);

			//**** rasterizeLine uses naive approach, looping through all pixels within line bounding box****//
			//rasterizeLine(dev_primitives[pid].v[0], dev_primitives[pid].v[1], dev_fragmentBuffer, dev_depth, height, width);
			//rasterizeLine(dev_primitives[pid].v[0], dev_primitives[pid].v[2], dev_fragmentBuffer, dev_depth, height, width);
			//rasterizeLine(dev_primitives[pid].v[1], dev_primitives[pid].v[2], dev_fragmentBuffer, dev_depth, height, width);
			//*******************Rasterize Line***********************//
		}
	}
}

/**
 * Perform rasterization.
 */
void rasterize(uchar4 *pbo, const glm::mat4 & MVP, const glm::mat4 & MV, const glm::mat3 MV_normal) {
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

		//Every scene contains multiple meshes.
		//Every mesh consists of multiple primitived
		//it is looping through meshes in the scene
		//p is looping through primitives of each mesh
		
		for (; it != itEnd; ++it) {
			auto p = (it->second).begin();	// each primitive
			auto pEnd = (it->second).end();
			for (; p != pEnd; ++p) {
				dim3 numBlocksForVertices((p->numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
				dim3 numBlocksForIndices((p->numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);

				_vertexTransformAndAssembly << < numBlocksForVertices, numThreadsPerBlock >> >(p->numVertices, *p, MVP, MV, MV_normal, width, height, 1);
				checkCUDAError("Vertex Processing");
				cudaDeviceSynchronize();
				_primitiveAssembly << < numBlocksForIndices, numThreadsPerBlock >> >
					(p->numIndices, 
					curPrimitiveBeginId, 
					dev_primitives, 
					*p);
				checkCUDAError("Primitive Assembly");

				curPrimitiveBeginId += p->numPrimitives;
			}
		}

		checkCUDAError("Vertex Processing and Primitive Assembly");
	}
	
	

	cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
	initDepth << <blockCount2d, blockSize2d >> >(width, height, dev_depth);
	
	// TODO: rasterize
	//dev_primitives
	dim3 numBlocksForPrimitives((totalNumPrimitives + 128- 1) / 128);

	timer().startGpuTimer();
	_rasterizePrimitive << <numBlocksForPrimitives, 128 >> > (curPrimitiveBeginId, dev_primitives, dev_fragmentBuffer, 
		dev_depth, height, width, Triangle);
	timer().endGpuTimer();

    // Copy depthbuffer colors into framebuffer
	
	render << <blockCount2d, blockSize2d >> >(width, height, dev_fragmentBuffer, dev_framebuffer, -sceneLightDir, lightIntensity, Triangle);
	
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

    checkCUDAError("rasterize Free");
}
