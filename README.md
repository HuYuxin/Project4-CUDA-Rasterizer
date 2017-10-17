CUDA Rasterizer
===============

[CLICK ME FOR INSTRUCTION OF THIS PROJECT](./INSTRUCTION.md)

**University of Pennsylvania, CIS 565: GPU Programming and Architecture, Project 4**

* Yuxin Hu
* Tested on: Windows 10, i7-6700HQ @ 2.60GHz 8GB, GTX 960M 4096MB (Personal Laptop)

### Yuxin Hu
## Code Change
* rasterize.cu. Add a new function parameters in function _vertexTransformAndAssembly: float scale. For objects that are too large to be displayed properly on screen, I will pass a scale parameters to resize it in model space.
* rasterize.cu. Add a kernal function _rasterizePrimitive to set value for fragment buffer. It has three modes: triangle, point and line.
* rasterize.cu. Add three function parameters in render() function. glm::vec3 lightDir & float lightIntensity: for light direction and light intensity that will be used for Lambert shading models. PrimitiveType mode: if it is point or line, do not apply shading model, if it is triangle, apply lambert shading model.
* rasterize.cu. Add a new function float getZByLerp, get depth of fragment on a line between two vertice.
* rasterize.cu. Add a new function rasterizeLine. A naive approach to loop through all pixels within line's bounding box, and check if each pixel falls on the line segment.
* rasterize.cu. Add a new function bresenhamLine. This is third party code taken reference from  http://tech-algorithm.com/articles/drawing-line-using-bresenham-algorithm/. It uses the Bresenhan Line Algorithm to shade fragments that form the line between two vertices.
* rasterize.cu. Add a new function rasterizeWireFrame. This will be called as a parent function of bresenhamLine.
* rasterize.h. Add the performance timer class PerformanceTimer, adapted from WindyDarian(https://github.com/WindyDarian).
* rasterizeTools.h. Add a new function getAABBForLine. Get the bounding box of the line segment.
* rasterizeTools.h. Add a new function getColorAtCoordinate. Get the color of the fragment using barycentric interpolation, without perspective correction.
* rasterizeTools.h. Add a new function getEyeSpaceZAtCoordinate. Get the eye space z at coordinate using barycentric interpolation.
* rasterizeTools.h. Add a new function getTextureAtCoord. Get the perspective corrected texture uv coordinate using barycentric interpolation.

## How to run different rasterize mode?
* Render primitives with lambert shading model: change the last parameter of below two kernal function calls in rasterize() to **Triangle**
_rasterizePrimitive (......, **Triangle**)
render << <blockCount2d, blockSize2d >> >(......, **Triangle**);

* Render primitives with point: change the last parameter of below two kernal function calls in rasterize() to **Point**
_rasterizePrimitive (......, **Point**)
render << <blockCount2d, blockSize2d >> >(......, **Point**);

* Render primitives with Lines: change the last parameter of below two kernal function calls  in rasterize() to **Line**
_rasterizePrimitive (......, **Line**)
render << <blockCount2d, blockSize2d >> >(......, **Line**);

* Render primitives with scale factor: change the last parameter of below kernal function call in rasteriza(), e.g. set it as 0.01 to render the two cylinder engine.
_vertexTransformAndAssembly(......, 0.01)


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
![Checker Box with Black and White Grid Texture](/renders/CheckerBoxPerspectiveCorrect.gif)
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

* Rasterize Kernal Run Time Versus Texture Read
![Rasterize Kernal Run Time Of Checkerbox](/renders/PerformanceTexture.PNG)
<p align="center"><b>Rasterize Kernal Run Time Of Checkerbox</b></p>

It takes twice the time to render checkerbox with texture read.

* Rasterize Line Methods Comparason
![Rasterize Line Methods Comparason](/renders/PerformanceLineRasterize.PNG)
<p align="center"><b>Rasterize Line Methods Comparason</b></p>
I used a naive approach to render lines, which is looping through all pixels within the line's bounding box, and check if each pixel falls on the line. I also tested the Bresenham line algorithm, which is the algorithm described in [this post](http://tech-algorithm.com/articles/drawing-line-using-bresenham-algorithm/).  The idea is that for line in first octanc, where the slop is between 0 and 1, we increment x every time, and we render either (x+1,y) or (x+1, y+1) based on which pixel is closer to the line. For lines in other octant, we simply convert them to the first octant and repeat the method. This method avoids looping through all pixels, where most of them are not falling on line. From the performance analysis we can observe that the Bresenham line algorithm has almost 4 times performance improvement than naive apprach.






### Credits

* [tinygltfloader](https://github.com/syoyo/tinygltfloader) by [@soyoyo](https://github.com/syoyo)
* [glTF Sample Models](https://github.com/KhronosGroup/glTF/blob/master/sampleModels/README.md)
* [Bresenham Line Algorithm Code](http://tech-algorithm.com/articles/drawing-line-using-bresenham-algorithm/)
