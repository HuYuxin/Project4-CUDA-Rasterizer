CUDA Rasterizer
===============

[CLICK ME FOR INSTRUCTION OF THIS PROJECT](./INSTRUCTION.md)

**University of Pennsylvania, CIS 565: GPU Programming and Architecture, Project 4**

* Yuxin Hu
* Tested on: Windows 10, i7-6700HQ @ 2.60GHz 8GB, GTX 960M 4096MB (Personal Laptop)

### Yuxin Hu
## Code Change
* rasterize.cu. Add a new function parameters in function _vertexTransformAndAssembly: float scale. For objects that are too large to be displayed properly on screen, I will pass a scale parameters to resize it in model space.
* rasterize.cu. Add a kernal function _rasterizePrimitive to set value for fragment buffer.
* rasterize.cu. Add two new function parameters in render() function. For light direction and light intensity that will be used for lighting models.

## Basic Rasterizer with Bounding Box and Depth Tested
![Flower Colored with Normals](/renders/FlowerNormal2.gif)
  <p align="center"><b>Flower Colored with Normals</b></p>

![Cow with Lambert Shadings] (/renders/Cow.gif)
  <p align="center"><b>Cow with Lambert Shadings</b></p>
  
![Double Cylinder Engine with Lamber Shadings](/renders/Engine.gif)
  <p align="center"><b>Double Cylinder Engine with Lamber Shadings</b></p>
  
![Double Cylinder Engine Scaled with 0.01](/renders/Engine001.gif)
  <p align="center"><b>Double Cylinder Engine Scaled with 0.01</b></p>
  
![Character Model with Lambert Shadings](/renders/Di.gif)
  <p align="center"><b>Character Model with Lambert Shadings</b></p>
  
## Interpolate Fragment Colors Within Triangle
![Color Interpolation Within Each Triangle](/renders/CubeColorInterpolation.PNG)
  <p align="center"><b>Color Interpolation Within Each Triangle</b></p>
  
## UV Texture Map
![Checker Box with Black and White Grid Texture](/renders/CheckerBox.gif)
  <p align="center"><b>Checker Box with Black and White Grid Texture</b></p>
  
![Yellow Duck with Texture](/renders/Duck.gif)
  <p align="center"><b>Yellow Duck with Texture</b></p>
  
![Cesium Milk Truck with Texture](/renders/CeciumMilkTruck.gif)
  <p align="center"><b>Cesium Milk Truck with Texture</b></p>
  
## Performance Analysis

### Credits

* [tinygltfloader](https://github.com/syoyo/tinygltfloader) by [@soyoyo](https://github.com/syoyo)
* [glTF Sample Models](https://github.com/KhronosGroup/glTF/blob/master/sampleModels/README.md)
