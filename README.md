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

![Cow with Lambert Shadings](/renders/Cow.gif)
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

## Point
![Box rendered with points](/renders/PointBox.gif)
<p align="center"><b>Box rendered with points only</b></p>

![Cow rendered with points](/renders/PointCow.gif)
<p align="center"><b>Cow rendered with points</b></p>

## Line
* Third party code reference: http://tech-algorithm.com/articles/drawing-line-using-bresenham-algorithm/
![Cow rendered with Lines](/renders/LineCow.gif)
<p align="center"><b>Cow rendered with lines</b></p>


  
## Performance Analysis
* Rasterize Kernal Run Time Versus Depth of Object along Camera Z
![Rasterize Kernal Run Time Versus Depth of Object](/renders/PerformanceDepth.PNG)
<p align="center"><b>Rasterize Kernal Run Time Versus Depth of Object</b></p>

In general the closer the objects toward camera, the longer it takes to complete rasterize kernal. Because the closer the objects are towards camera, the larger area each triangle will occupy in the screen space. In the rasterize primitive kernal we need to loop over more pixels. The number of triangles does not affect the performance. More triangles (complex engine scaled at 0.01) does not necessary take more time to complete. From the sudden increase of run time between -2 and -1, it is clear that the bottleneck is the occupancy of the triangles on screen. At a very close distance, a few triangle will be rendering on screen, but each of them almost take entire screen space, and we have to loop over all pixels within the bounding box, which severely affects performance.


### Credits

* [tinygltfloader](https://github.com/syoyo/tinygltfloader) by [@soyoyo](https://github.com/syoyo)
* [glTF Sample Models](https://github.com/KhronosGroup/glTF/blob/master/sampleModels/README.md)
