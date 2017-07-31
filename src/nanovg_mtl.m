// Copyright (c) 2017 Ollix
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// ---
// Author: olliwang@ollix.com (Olli Wang)

#include "nanovg_mtl.h"

#include <math.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#import <simd/simd.h>
#import <Metal/Metal.h>
#include <TargetConditionals.h>
#import <QuartzCore/QuartzCore.h>

#include "nanovg.h"

#if TARGET_OS_IOS == 1
#  include "nanovg_mtl_library_iphoneos.h"
#elif TARGET_OS_TV == 1
#  include "nanovg_mtl_library_appletvos.h"
#elif TARGET_OS_OSX == 1
#  include "nanovg_mtl_library_macosx.h"
#else
#  define MNVG_INVALID_TARGET
#endif

typedef enum MNVGvertexInputIndex {
  MNVG_VERTEX_INPUT_INDEX_VERTICES = 0,
  MNVG_VERTEX_INPUT_INDEX_VIEW_SIZE = 1,
} MNVGvertexInputIndex;

typedef enum MNVGshaderType {
  MNVG_SHADER_FILLGRAD,
  MNVG_SHADER_FILLIMG,
  MNVG_SHADER_IMG,
} MNVGshaderType;

enum MNVGcallType {
  MNVG_NONE = 0,
  MNVG_FILL,
  MNVG_CONVEXFILL,
  MNVG_STROKE,
  MNVG_TRIANGLES,
};

struct MNVGblend {
  MTLBlendFactor srcRGB;
  MTLBlendFactor dstRGB;
  MTLBlendFactor srcAlpha;
  MTLBlendFactor dstAlpha;
};
typedef struct MNVGblend MNVGblend;

struct MNVGcall {
  int type;
  int image;
  int pathOffset;
  int pathCount;
  int triangleOffset;
  int triangleCount;
  int indexOffset;
  int indexCount;
  int uniformOffset;
  MNVGblend blendFunc;
};
typedef struct MNVGcall MNVGcall;

struct MNVGpath {
  int fillOffset;
  int fillCount;
  int strokeOffset;
  int strokeCount;
};
typedef struct MNVGpath MNVGpath;

struct MNVGtexture {
  int id;
  id<MTLTexture> tex;
  id<MTLSamplerState> sampler;
  int type;
  int flags;
};
typedef struct MNVGtexture MNVGtexture;

struct MNVGfragUniforms {
  matrix_float3x3 scissorMat;
  matrix_float3x3 paintMat;
  vector_float4 innerCol;
  vector_float4 outerCol;
  vector_float2 scissorExt;
  vector_float2 scissorScale;
  vector_float2 extent;
  float radius;
  float feather;
  float strokeMult;
  float strokeThr;
  int texType;
  MNVGshaderType type;
};
typedef struct MNVGfragUniforms MNVGfragUniforms;

struct MNVGcontext {
  id <MTLCommandBuffer> commandBuffer;
  id<MTLCommandQueue> commandQueue;
  id<CAMetalDrawable> drawable;
  CAMetalLayer* metalLayer;
  id <MTLRenderCommandEncoder> renderEncoder;

  int fragSize;
  int indexSize;
  int flags;
  float devicePixelRatio;
  vector_uint2 viewPortSize;

  // Textures
  MNVGtexture* textures;
  int ntextures;
  int ctextures;
  int textureId;

  // Per frame buffers
  MNVGcall* calls;
  int ccalls;
  int ncalls;
  MNVGpath* paths;
  int cpaths;
  int npaths;
  id<MTLBuffer> indexBuffer;
  uint16_t* indexes;
  int cindexes;
  int nindexes;
  id<MTLBuffer> vertBuffer;
  struct NVGvertex* verts;
  int cverts;
  int nverts;
  id<MTLBuffer> uniformBuffer;
  unsigned char* uniforms;
  int cuniforms;
  int nuniforms;

  // Cached states.
  MNVGblend blendFunc;
  id<MTLBuffer> viewSizeBuffer;
  id<MTLDepthStencilState> defaultStencilState;
  id<MTLDepthStencilState> fillShapeStencilState;
  id<MTLDepthStencilState> fillAntiAliasStencilState;
  id<MTLDepthStencilState> fillStencilState;
  id<MTLDepthStencilState> strokeShapeStencilState;
  id<MTLDepthStencilState> strokeAntiAliasStencilState;
  id<MTLDepthStencilState> strokeClearStencilState;
  id<MTLFunction> fragmentFunction;
  id<MTLFunction> vertexFunction;
  id<MTLRenderPipelineState> pipelineState;
  id<MTLRenderPipelineState> stencilOnlyPipelineState;
  id<MTLSamplerState> pseudoSampler;
  id<MTLTexture> stencilTexture;
  id<MTLTexture> depthTexture;
  MTLVertexDescriptor* vertexDescriptor;
};
typedef struct MNVGcontext MNVGcontext;

const MTLResourceOptions kMetalBufferOptions = \
    (MTLResourceCPUCacheModeWriteCombined | MTLResourceStorageModeShared);

static int mtlnvg__maxi(int a, int b) { return a > b ? a : b; }

static MNVGcall* mtlnvg__allocCall(MNVGcontext* mtl) {
  MNVGcall* ret = NULL;
  if (mtl->ncalls+1 > mtl->ccalls) {
    MNVGcall* calls;
    int ccalls = mtlnvg__maxi(mtl->ncalls + 1, 128) + mtl->ccalls / 2; // 1.5x Overallocate
    calls = (MNVGcall*)realloc(mtl->calls, sizeof(MNVGcall) * ccalls);
    if (calls == NULL) return NULL;
    mtl->calls = calls;
    mtl->ccalls = ccalls;
  }
  ret = &mtl->calls[mtl->ncalls++];
  memset(ret, 0, sizeof(MNVGcall));
  return ret;
}

static int mtlnvg__allocFragUniforms(MNVGcontext* mtl, int n) {
  int ret = 0;
  if (mtl->nuniforms + n > mtl->cuniforms) {
    int cuniforms = mtlnvg__maxi(mtl->nuniforms + n, 128) + mtl->cuniforms / 2;
    id<MTLBuffer> buffer = [mtl->metalLayer.device
        newBufferWithLength:(mtl->fragSize * cuniforms)
        options:kMetalBufferOptions];
    unsigned char* uniforms = [buffer contents];
    if (mtl->uniformBuffer != nil) {
      memcpy(uniforms, mtl->uniforms, mtl->fragSize * mtl->nuniforms);
      [mtl->uniformBuffer release];
    }
    mtl->uniformBuffer = buffer;
    mtl->uniforms = uniforms;
    mtl->cuniforms = cuniforms;
  }
  ret = mtl->nuniforms * mtl->fragSize;
  mtl->nuniforms += n;
  return ret;
}

static int mtlnvg__allocPaths(MNVGcontext* mtl, int n) {
  int ret = 0;
  if (mtl->npaths + n > mtl->cpaths) {
    MNVGpath* paths;
    int cpaths = mtlnvg__maxi(mtl->npaths + n, 128) + mtl->cpaths / 2;
    paths = (MNVGpath*)realloc(mtl->paths, sizeof(MNVGpath) * cpaths);
    if (paths == NULL) return -1;
    mtl->paths = paths;
    mtl->cpaths = cpaths;
  }
  ret = mtl->npaths;
  mtl->npaths += n;
  return ret;
}

static MNVGtexture* mtlnvg__allocTexture(MNVGcontext* mtl) {
  MNVGtexture* tex = NULL;

  for (int i = 0; i < mtl->ntextures; i++) {
    if (mtl->textures[i].id == 0) {
      tex = &mtl->textures[i];
      break;
    }
  }
  if (tex == NULL) {
    if (mtl->ntextures + 1 > mtl->ctextures) {
      int ctextures = mtlnvg__maxi(mtl->ntextures + 1, 4) + mtl->ctextures / 2;
      MNVGtexture* textures = (MNVGtexture*)realloc(
          mtl->textures, sizeof(MNVGtexture) * ctextures);
      if (textures == NULL) return NULL;
      mtl->textures = textures;
      mtl->ctextures = ctextures;
    }
    tex = &mtl->textures[mtl->ntextures++];
  }
  memset(tex, 0, sizeof(MNVGtexture));
  tex->id = ++mtl->textureId;
  return tex;
}

static int mtlnvg__allocIndexes(MNVGcontext* mtl, int n) {
  int ret = 0;
  if (mtl->nindexes + n > mtl->cindexes) {
    int cindexes = mtlnvg__maxi(mtl->nindexes + n, 4096) + mtl->cindexes / 2;
    id<MTLBuffer> buffer = [mtl->metalLayer.device
        newBufferWithLength:(mtl->indexSize * cindexes)
        options:kMetalBufferOptions];
    uint16_t* indexes = [buffer contents];
    if (mtl->indexBuffer != nil) {
      memcpy(indexes, mtl->indexes, mtl->indexSize * mtl->nindexes);
      [mtl->indexBuffer release];
    }
    mtl->indexBuffer = buffer;
    mtl->indexes = indexes;
    mtl->cindexes = cindexes;
  }
  ret = mtl->nindexes;
  mtl->nindexes += n;
  return ret;
}

static int mtlnvg__allocVerts(MNVGcontext* mtl, int n) {
  int ret = 0;
  if (mtl->nverts + n > mtl->cverts) {
    int cverts = mtlnvg__maxi(mtl->nverts + n, 4096) + mtl->cverts / 2;
    id<MTLBuffer> buffer = [mtl->metalLayer.device
        newBufferWithLength:(sizeof(NVGvertex) * cverts)
        options:kMetalBufferOptions];
    NVGvertex* verts = [buffer contents];
    if (mtl->vertBuffer != nil) {
      memcpy(verts, mtl->verts, sizeof(NVGvertex) * mtl->nverts);
      [mtl->vertBuffer release];
    }
    mtl->vertBuffer = buffer;
    mtl->verts = verts;
    mtl->cverts = cverts;
  }
  ret = mtl->nverts;
  mtl->nverts += n;
  return ret;
}

static BOOL mtlnvg_convertBlendFuncFactor(int factor, MTLBlendFactor* result) {
  if (factor == NVG_ZERO)
    *result = MTLBlendFactorZero;
  else if (factor == NVG_ONE)
    *result = MTLBlendFactorOne;
  else if (factor == NVG_SRC_COLOR)
    *result = MTLBlendFactorSourceColor;
  else if (factor == NVG_ONE_MINUS_SRC_COLOR)
    *result = MTLBlendFactorOneMinusSourceColor;
  else if (factor == NVG_DST_COLOR)
    *result = MTLBlendFactorDestinationColor;
  else if (factor == NVG_ONE_MINUS_DST_COLOR)
    *result = MTLBlendFactorOneMinusDestinationColor;
  else if (factor == NVG_SRC_ALPHA)
    *result = MTLBlendFactorSourceAlpha;
  else if (factor == NVG_ONE_MINUS_SRC_ALPHA)
    *result = MTLBlendFactorOneMinusSourceAlpha;
  else if (factor == NVG_DST_ALPHA)
    *result = MTLBlendFactorDestinationAlpha;
  else if (factor == NVG_ONE_MINUS_DST_ALPHA)
    *result = MTLBlendFactorOneMinusDestinationAlpha;
  else if (factor == NVG_SRC_ALPHA_SATURATE)
    *result = MTLBlendFactorSourceAlphaSaturated;
  else
    return NO;
  return YES;
}

static MNVGblend mtlnvg__blendCompositeOperation(NVGcompositeOperationState op) {
  MNVGblend blend;
  if (!mtlnvg_convertBlendFuncFactor(op.srcRGB, &blend.srcRGB) ||
      !mtlnvg_convertBlendFuncFactor(op.dstRGB, &blend.dstRGB) ||
      !mtlnvg_convertBlendFuncFactor(op.srcAlpha, &blend.srcAlpha) ||
      !mtlnvg_convertBlendFuncFactor(op.dstAlpha, &blend.dstAlpha)) {
    blend.srcRGB = MTLBlendFactorOne;
    blend.dstRGB = MTLBlendFactorOneMinusSourceAlpha;
    blend.srcAlpha = MTLBlendFactorOne;
    blend.dstAlpha = MTLBlendFactorOneMinusSourceAlpha;
  }
  return blend;
}

static void mtlnvg__checkError(MNVGcontext* mtl, const char* str,
                               NSError* error) {
  if ((mtl->flags & NVG_DEBUG) == 0) return;
  if (error) {
    printf("Error occurs after %s: %s\n", str, [[error localizedDescription] UTF8String]);
  }
}

static MNVGtexture* mtlnvg__findTexture(MNVGcontext* mtl, int id) {
  for (int i = 0; i < mtl->ntextures; i++) {
    if (mtl->textures[i].id == id)
      return &mtl->textures[i];
  }
  return NULL;
}

static vector_float4 mtlnvg__premulColor(NVGcolor c)
{
  c.r *= c.a;
  c.g *= c.a;
  c.b *= c.a;
  return (vector_float4){c.r, c.g, c.b, c.a};
}

static void mtlnvg__xformToMat3x3(matrix_float3x3* m3, float* t) {
  *m3 = matrix_from_columns((vector_float3){t[0], t[1], 0.0f},
                            (vector_float3){t[2], t[3], 0.0f},
                            (vector_float3){t[4], t[5], 1.0f});
}

static int mtlnvg__convertPaint(MNVGcontext* mtl, MNVGfragUniforms* frag,
                                NVGpaint* paint, NVGscissor* scissor,
                                float width, float fringe, float strokeThr) {
  MNVGtexture* tex = NULL;
  float invxform[6];

  memset(frag, 0, sizeof(*frag));

  frag->innerCol = mtlnvg__premulColor(paint->innerColor);
  frag->outerCol = mtlnvg__premulColor(paint->outerColor);

  if (scissor->extent[0] < -0.5f || scissor->extent[1] < -0.5f) {
    frag->scissorMat = matrix_from_rows((vector_float3){0, 0, 0},
                                        (vector_float3){0, 0, 0},
                                        (vector_float3){0, 0, 0});
    frag->scissorExt.x = 1.0f;
    frag->scissorExt.y = 1.0f;
    frag->scissorScale.x = 1.0f;
    frag->scissorScale.y = 1.0f;
  } else {
    nvgTransformInverse(invxform, scissor->xform);
    mtlnvg__xformToMat3x3(&frag->scissorMat, invxform);
    frag->scissorExt.x = scissor->extent[0];
    frag->scissorExt.y = scissor->extent[1];
    frag->scissorScale.x = sqrtf(scissor->xform[0] * scissor->xform[0] + scissor->xform[2] * scissor->xform[2]) / fringe;
    frag->scissorScale.y = sqrtf(scissor->xform[1] * scissor->xform[1] + scissor->xform[3] * scissor->xform[3]) / fringe;
  }

  frag->extent = (vector_float2){paint->extent[0], paint->extent[1]};
  frag->strokeMult = (width * 0.5f + fringe * 0.5f) / fringe;
  frag->strokeThr = strokeThr;

  if (paint->image != 0) {
    tex = mtlnvg__findTexture(mtl, paint->image);
    if (tex == NULL) return 0;
    if (tex->flags & NVG_IMAGE_FLIPY) {
      float m1[6], m2[6];
      nvgTransformTranslate(m1, 0.0f, frag->extent.y * 0.5f);
      nvgTransformMultiply(m1, paint->xform);
      nvgTransformScale(m2, 1.0f, -1.0f);
      nvgTransformMultiply(m2, m1);
      nvgTransformTranslate(m1, 0.0f, -frag->extent.y * 0.5f);
      nvgTransformMultiply(m1, m2);
      nvgTransformInverse(invxform, m1);
    } else {
      nvgTransformInverse(invxform, paint->xform);
    }
    frag->type = MNVG_SHADER_FILLIMG;

    if (tex->type == NVG_TEXTURE_RGBA)
      frag->texType = (tex->flags & NVG_IMAGE_PREMULTIPLIED) ? 0 : 1;
    else
      frag->texType = 2;
  } else {
    frag->type = MNVG_SHADER_FILLGRAD;
    frag->radius = paint->radius;
    frag->feather = paint->feather;
    nvgTransformInverse(invxform, paint->xform);
  }

  mtlnvg__xformToMat3x3(&frag->paintMat, invxform);

  return 1;
}

static MNVGfragUniforms* mtlnvg__fragUniformPtr(MNVGcontext* mtl, int i) {
  return (MNVGfragUniforms*)&mtl->uniforms[i];
}

static int mtlnvg__maxVertCount(const NVGpath* paths, int npaths,
                                int* index_count) {
  int i, count = 0;
  if (index_count != NULL)
    *index_count = 0;
  for (i = 0; i < npaths; i++) {
    count += paths[i].nfill;
    count += paths[i].nstroke;
    if (index_count != NULL)
      *index_count += (paths[i].nfill - 2) * 3;
  }
  return count;
}

static id<MTLRenderCommandEncoder> mtlnvg__renderCommandEncoder(
    MNVGcontext* mtl) {
  MTLRenderPassDescriptor *descriptor = \
      [MTLRenderPassDescriptor renderPassDescriptor];
  descriptor.colorAttachments[0].texture = mtl->drawable.texture;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
  descriptor.stencilAttachment.texture = mtl->stencilTexture;
  descriptor.stencilAttachment.storeAction = MTLStoreActionDontCare;

  descriptor.colorAttachments[0].clearColor = \
      MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
  descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
  descriptor.stencilAttachment.clearStencil = 0;
  descriptor.stencilAttachment.loadAction = MTLLoadActionClear;

  id<MTLRenderCommandEncoder> encoder = [mtl->commandBuffer
      renderCommandEncoderWithDescriptor:descriptor];

  [encoder setCullMode:MTLCullModeBack];
  [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
  [encoder setStencilReferenceValue:0];
  [encoder setViewport:(MTLViewport)
      {0.0, 0.0, mtl->viewPortSize.x, mtl->viewPortSize.y, 0.0, 1.0}];

  [encoder setVertexBuffer:mtl->vertBuffer
                    offset:0
                   atIndex:MNVG_VERTEX_INPUT_INDEX_VERTICES];

  [encoder setVertexBuffer:mtl->viewSizeBuffer
                   offset:0
                  atIndex:MNVG_VERTEX_INPUT_INDEX_VIEW_SIZE];

  return encoder;
}

static void mtlnvg__setUniforms(MNVGcontext* mtl, int uniformOffset,
                                int image) {
  [mtl->renderEncoder setFragmentBuffer:mtl->uniformBuffer
                                 offset:uniformOffset
                                atIndex:0];

  MNVGtexture* tex = (image == 0 ? NULL : mtlnvg__findTexture(mtl, image));
  if (tex != NULL) {
    [mtl->renderEncoder setFragmentTexture:tex->tex atIndex:0];
    [mtl->renderEncoder setFragmentSamplerState:tex->sampler atIndex:0];
  } else {
    [mtl->renderEncoder setFragmentTexture:nil atIndex:0];
    [mtl->renderEncoder setFragmentSamplerState:mtl->pseudoSampler atIndex:0];
  }
}

static void mtlnvg__updateRenderPipelineStates(MNVGcontext* mtl,
                                               MNVGblend* blend) {
  if (mtl->pipelineState != nil &&
      mtl->stencilOnlyPipelineState != nil &&
      mtl->blendFunc.srcRGB == blend->srcRGB &&
      mtl->blendFunc.dstRGB == blend->dstRGB &&
      mtl->blendFunc.srcAlpha == blend->srcAlpha &&
      mtl->blendFunc.dstAlpha == blend->dstAlpha) {
    return;
  }

  if (mtl->pipelineState != nil) {
    [mtl->pipelineState release];
    mtl->pipelineState = nil;
  }
  if (mtl->stencilOnlyPipelineState != nil) {
    [mtl->stencilOnlyPipelineState release];
    mtl->stencilOnlyPipelineState = nil;
  }

  MTLRenderPipelineDescriptor *pipelineStateDescriptor = \
      [MTLRenderPipelineDescriptor new];

  MTLRenderPipelineColorAttachmentDescriptor* colorAttachmentDescriptor = \
      pipelineStateDescriptor.colorAttachments[0];
  colorAttachmentDescriptor.pixelFormat = mtl->metalLayer.pixelFormat;
  pipelineStateDescriptor.stencilAttachmentPixelFormat = MTLPixelFormatStencil8;
  pipelineStateDescriptor.fragmentFunction = mtl->fragmentFunction;
  pipelineStateDescriptor.vertexFunction = mtl->vertexFunction;
  pipelineStateDescriptor.vertexDescriptor = mtl->vertexDescriptor;

  // Sets blending states.
  colorAttachmentDescriptor.blendingEnabled = YES;
  colorAttachmentDescriptor.sourceRGBBlendFactor = blend->srcRGB;
  colorAttachmentDescriptor.sourceAlphaBlendFactor = blend->srcAlpha;
  colorAttachmentDescriptor.destinationRGBBlendFactor = blend->dstRGB;
  colorAttachmentDescriptor.destinationAlphaBlendFactor = blend->dstAlpha;
  mtl->blendFunc.srcRGB = blend->srcRGB;
  mtl->blendFunc.srcAlpha = blend->srcAlpha;
  mtl->blendFunc.dstRGB = blend->dstRGB;
  mtl->blendFunc.dstAlpha = blend->dstAlpha;

  NSError* error;
  mtl->pipelineState = [mtl->metalLayer.device
      newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
                                     error:&error];
  mtlnvg__checkError(mtl, "init pipeline state", error);

  pipelineStateDescriptor.fragmentFunction = nil;
  colorAttachmentDescriptor.writeMask = MTLColorWriteMaskNone;
  mtl->stencilOnlyPipelineState = [mtl->metalLayer.device
      newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
                                     error:&error];
  mtlnvg__checkError(mtl, "init pipeline stencil only state", error);

  [pipelineStateDescriptor release];
}

static void mtlnvg__vset(NVGvertex* vtx, float x, float y, float u, float v) {
  vtx->x = x;
  vtx->y = y;
  vtx->u = u;
  vtx->v = v;
}

static void mtlnvg__fill(MNVGcontext* mtl, MNVGcall* call) {
  MNVGpath* paths = &mtl->paths[call->pathOffset];
  int i, npaths = call->pathCount;

  // Draws shapes.
  const int kIndexBufferOffset = call->indexOffset * mtl->indexSize;
  [mtl->renderEncoder setCullMode:MTLCullModeNone];
  [mtl->renderEncoder setDepthStencilState:mtl->fillShapeStencilState];
  [mtl->renderEncoder setRenderPipelineState:mtl->stencilOnlyPipelineState];
  [mtl->renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                 indexCount:call->indexCount
                                  indexType:MTLIndexTypeUInt16
                                indexBuffer:mtl->indexBuffer
                          indexBufferOffset:kIndexBufferOffset];

  // Restores states.
  [mtl->renderEncoder setCullMode:MTLCullModeBack];
  [mtl->renderEncoder setRenderPipelineState:mtl->pipelineState];

  // Draws anti-aliased fragments.
  mtlnvg__setUniforms(mtl, call->uniformOffset, call->image);
  if (mtl->flags & NVG_ANTIALIAS) {
    [mtl->renderEncoder setDepthStencilState:mtl->fillAntiAliasStencilState];
    for (i = 0; i < npaths; i++) {
      [mtl->renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                             vertexStart:paths[i].strokeOffset
                             vertexCount:paths[i].strokeCount];
    }
  }

  // Draws fill.
  [mtl->renderEncoder setDepthStencilState:mtl->fillStencilState];
  [mtl->renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                         vertexStart:call->triangleOffset
                         vertexCount:call->triangleCount];

  [mtl->renderEncoder setDepthStencilState:mtl->defaultStencilState];
}

static void mtlnvg__convexFill(MNVGcontext* mtl, MNVGcall* call) {
  MNVGpath* paths = &mtl->paths[call->pathOffset];
  int i, npaths = call->pathCount;

  const int kIndexBufferOffset = call->indexOffset * mtl->indexSize;
  mtlnvg__setUniforms(mtl, call->uniformOffset, call->image);
  [mtl->renderEncoder setRenderPipelineState:mtl->pipelineState];
  [mtl->renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                 indexCount:call->indexCount
                                  indexType:MTLIndexTypeUInt16
                                indexBuffer:mtl->indexBuffer
                          indexBufferOffset:kIndexBufferOffset];

  // Draw fringes
  if (mtl->flags & NVG_ANTIALIAS) {
    for (i = 0; i < npaths; i++) {
      [mtl->renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                             vertexStart:paths[i].strokeOffset
                             vertexCount:paths[i].strokeCount];
    }
  }
}

static void mtlnvg__stroke(MNVGcontext* mtl, MNVGcall* call) {
  MNVGpath* paths = &mtl->paths[call->pathOffset];
  int i, npaths = call->pathCount;

  if (mtl->flags & NVG_STENCIL_STROKES) {
    // Fills the stroke base without overlap.
    mtlnvg__setUniforms(mtl, call->uniformOffset + mtl->fragSize, call->image);
    [mtl->renderEncoder setDepthStencilState:mtl->strokeShapeStencilState];
    [mtl->renderEncoder setRenderPipelineState:mtl->pipelineState];
    for (i = 0; i < npaths; i++) {
      [mtl->renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                             vertexStart:paths[i].strokeOffset
                             vertexCount:paths[i].strokeCount];
    }

    // Draws anti-aliased fragments.
    mtlnvg__setUniforms(mtl, call->uniformOffset, call->image);
    [mtl->renderEncoder setDepthStencilState:mtl->strokeAntiAliasStencilState];
    for (i = 0; i < npaths; i++) {
      [mtl->renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                             vertexStart:paths[i].strokeOffset
                             vertexCount:paths[i].strokeCount];
    }

    // Clears stencil buffer.
    [mtl->renderEncoder setDepthStencilState:mtl->strokeClearStencilState];
    [mtl->renderEncoder setRenderPipelineState:mtl->stencilOnlyPipelineState];
    for (i = 0; i < npaths; i++) {
      [mtl->renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                             vertexStart:paths[i].strokeOffset
                             vertexCount:paths[i].strokeCount];
    }

    [mtl->renderEncoder setDepthStencilState:mtl->defaultStencilState];
  } else {
    // Draws strokes.
    mtlnvg__setUniforms(mtl, call->uniformOffset, call->image);
    [mtl->renderEncoder setRenderPipelineState:mtl->pipelineState];
    for (i = 0; i < npaths; i++) {
      [mtl->renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                             vertexStart:paths[i].strokeOffset
                             vertexCount:paths[i].strokeCount];
    }
  }
}

static void mtlnvg__triangles(MNVGcontext* mtl, MNVGcall* call) {
  mtlnvg__setUniforms(mtl, call->uniformOffset, call->image);
  [mtl->renderEncoder setRenderPipelineState:mtl->pipelineState];
  [mtl->renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                         vertexStart:call->triangleOffset
                         vertexCount:call->triangleCount];
}

static void mtlnvg__renderCancel(void* uptr) {
  MNVGcontext* mtl = (MNVGcontext*)uptr;
  mtl->nindexes = 0;
  mtl->nverts = 0;
  mtl->npaths = 0;
  mtl->ncalls = 0;
  mtl->nuniforms = 0;
}

static int mtlnvg__renderCreate(void* uptr) {
  MNVGcontext* mtl = (MNVGcontext*)uptr;

  if (mtl->metalLayer.device == nil) {
    mtl->metalLayer.device = MTLCreateSystemDefaultDevice();
  }
  mtl->metalLayer.drawableSize = CGSizeMake(mtl->viewPortSize.x,
                                            mtl->viewPortSize.y);
  mtl->metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;

  // Loads shaders from pre-compiled metal library..
  NSError* error;
  id<MTLDevice> device = mtl->metalLayer.device;
#ifdef MNVG_INVALID_TARGET
  id<MTLLibrary> library = nil;
#else
  dispatch_data_t data = dispatch_data_create(nanovg_mtl_library,
                                              nanovg_mtl_library_len,
                                              NULL,
                                              DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  id<MTLLibrary> library = [device newLibraryWithData:data error:&error];
  [data release];
#endif

  mtlnvg__checkError(mtl, "init library", error);
  if (library == nil) {
    return 0;
  }

  mtl->vertexFunction = [library newFunctionWithName:@"vertexShader"];
  mtl->fragmentFunction = \
      mtl->flags & NVG_ANTIALIAS ?
      [library newFunctionWithName:@"fragmentShaderAA"] :
      [library newFunctionWithName:@"fragmentShader"];

  mtl->commandQueue = [device newCommandQueue];

  // Initializes vertex descriptor.
  mtl->vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
  [mtl->vertexDescriptor retain];
  mtl->vertexDescriptor.attributes[0].format = MTLVertexFormatFloat2;
  mtl->vertexDescriptor.attributes[0].bufferIndex = 0;
  mtl->vertexDescriptor.attributes[0].offset = offsetof(NVGvertex, x);

  mtl->vertexDescriptor.attributes[1].format = MTLVertexFormatFloat2;
  mtl->vertexDescriptor.attributes[1].bufferIndex = 0;
  mtl->vertexDescriptor.attributes[1].offset = offsetof(NVGvertex, u);

  mtl->vertexDescriptor.layouts[0].stride = sizeof(NVGvertex);
  mtl->vertexDescriptor.layouts[0].stepFunction = \
      MTLVertexStepFunctionPerVertex;

  // Initializes default sampler descriptor.
  MTLSamplerDescriptor* samplerDescriptor = [MTLSamplerDescriptor new];
  mtl->pseudoSampler = [mtl->metalLayer.device
      newSamplerStateWithDescriptor:samplerDescriptor];
  [samplerDescriptor release];

  // Initializes default blend states.
  mtl->blendFunc.srcRGB = MTLBlendFactorOne;
  mtl->blendFunc.srcAlpha = MTLBlendFactorOne;
  mtl->blendFunc.dstRGB = MTLBlendFactorOneMinusSourceAlpha;
  mtl->blendFunc.dstAlpha = MTLBlendFactorOneMinusSourceAlpha;

  // Initializes stencil states.
  MTLDepthStencilDescriptor* stencilDescriptor = \
      [MTLDepthStencilDescriptor new];

  // Default stencil state.
  mtl->defaultStencilState = [device
      newDepthStencilStateWithDescriptor:stencilDescriptor];

  // Fill shape stencil.
  MTLStencilDescriptor* frontFaceStencilDescriptor = [MTLStencilDescriptor new];
  frontFaceStencilDescriptor.stencilCompareFunction = MTLCompareFunctionAlways;
  frontFaceStencilDescriptor.depthStencilPassOperation = \
      MTLStencilOperationIncrementWrap;

  MTLStencilDescriptor* backFaceStencilDescriptor = [MTLStencilDescriptor new];
  backFaceStencilDescriptor.stencilCompareFunction = MTLCompareFunctionAlways;
  backFaceStencilDescriptor.depthStencilPassOperation = \
      MTLStencilOperationDecrementWrap;

  stencilDescriptor.depthCompareFunction = MTLCompareFunctionAlways;
  stencilDescriptor.backFaceStencil = backFaceStencilDescriptor;
  stencilDescriptor.frontFaceStencil = frontFaceStencilDescriptor;
  mtl->fillShapeStencilState = [device
      newDepthStencilStateWithDescriptor:stencilDescriptor];

  // Fill anti-aliased stencil.
  frontFaceStencilDescriptor.stencilCompareFunction = MTLCompareFunctionEqual;
  frontFaceStencilDescriptor.stencilFailureOperation = MTLStencilOperationKeep;
  frontFaceStencilDescriptor.depthFailureOperation = MTLStencilOperationKeep;
  frontFaceStencilDescriptor.depthStencilPassOperation = \
      MTLStencilOperationZero;

  stencilDescriptor.backFaceStencil = nil;
  stencilDescriptor.frontFaceStencil = frontFaceStencilDescriptor;
  mtl->fillAntiAliasStencilState = [device
      newDepthStencilStateWithDescriptor:stencilDescriptor];

  // Fill stencil.
  frontFaceStencilDescriptor.stencilCompareFunction = \
      MTLCompareFunctionNotEqual;
  frontFaceStencilDescriptor.stencilFailureOperation = MTLStencilOperationZero;
  frontFaceStencilDescriptor.depthFailureOperation = MTLStencilOperationZero;
  frontFaceStencilDescriptor.depthStencilPassOperation = \
      MTLStencilOperationZero;

  stencilDescriptor.backFaceStencil = nil;
  stencilDescriptor.frontFaceStencil = frontFaceStencilDescriptor;
  mtl->fillStencilState = [device
      newDepthStencilStateWithDescriptor:stencilDescriptor];

  // Stroke shape stencil.
  frontFaceStencilDescriptor.stencilCompareFunction = MTLCompareFunctionEqual;
  frontFaceStencilDescriptor.stencilFailureOperation = MTLStencilOperationKeep;
  frontFaceStencilDescriptor.depthFailureOperation = MTLStencilOperationKeep;
  frontFaceStencilDescriptor.depthStencilPassOperation = \
      MTLStencilOperationIncrementClamp;

  stencilDescriptor.backFaceStencil = nil;
  stencilDescriptor.frontFaceStencil = frontFaceStencilDescriptor;
  mtl->strokeShapeStencilState = [device
      newDepthStencilStateWithDescriptor:stencilDescriptor];

  // Stroke anti-aliased stencil.
  frontFaceStencilDescriptor.depthStencilPassOperation = \
      MTLStencilOperationKeep;

  stencilDescriptor.backFaceStencil = nil;
  stencilDescriptor.frontFaceStencil = frontFaceStencilDescriptor;
  mtl->strokeAntiAliasStencilState = [device
      newDepthStencilStateWithDescriptor:stencilDescriptor];

  // Stroke clear stencil.
  frontFaceStencilDescriptor.stencilCompareFunction = MTLCompareFunctionAlways;
  frontFaceStencilDescriptor.stencilFailureOperation = MTLStencilOperationZero;
  frontFaceStencilDescriptor.depthFailureOperation = MTLStencilOperationZero;
  frontFaceStencilDescriptor.depthStencilPassOperation = \
      MTLStencilOperationZero;

  stencilDescriptor.backFaceStencil = nil;
  stencilDescriptor.frontFaceStencil = frontFaceStencilDescriptor;
  mtl->strokeClearStencilState = [device
      newDepthStencilStateWithDescriptor:stencilDescriptor];

  [frontFaceStencilDescriptor release];
  [backFaceStencilDescriptor release];
  [stencilDescriptor release];

  return 1;
}

static int mtlnvg__renderCreateTexture(void* uptr, int type, int width,
                                       int height, int imageFlags,
                                       const unsigned char* data) {
  MNVGcontext* mtl = (MNVGcontext*)uptr;
  MNVGtexture* tex = mtlnvg__allocTexture(mtl);

  if (tex == NULL) return 0;

  MTLPixelFormat pixelFormat = MTLPixelFormatRGBA8Unorm;
  if (type == NVG_TEXTURE_ALPHA) {
    pixelFormat = MTLPixelFormatR8Unorm;
  }

  tex->type = type;
  tex->flags = imageFlags;

  MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:pixelFormat
      width:width
      height:height
      mipmapped:(imageFlags & NVG_IMAGE_GENERATE_MIPMAPS ? YES : NO)];
  tex->tex = [mtl->metalLayer.device
      newTextureWithDescriptor:textureDescriptor];

  if (data != NULL) {
    NSUInteger bytesPerRow;
    if (tex->type == NVG_TEXTURE_RGBA) {
      bytesPerRow = width * 4;
    } else {
      bytesPerRow = width;
    }

    [tex->tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
                mipmapLevel:0
                  withBytes:data
                bytesPerRow:bytesPerRow];

    if (imageFlags & NVG_IMAGE_GENERATE_MIPMAPS) {
      id<MTLCommandBuffer> commandBuffer = [mtl->commandQueue commandBuffer];
      id<MTLBlitCommandEncoder> encoder = [commandBuffer blitCommandEncoder];
      [encoder generateMipmapsForTexture:tex->tex];
      [encoder endEncoding];
      [commandBuffer commit];
      [commandBuffer waitUntilCompleted];
    }
  }

  MTLSamplerDescriptor* samplerDescriptor = [MTLSamplerDescriptor new];
  if (imageFlags & NVG_IMAGE_NEAREST) {
    samplerDescriptor.minFilter = MTLSamplerMinMagFilterNearest;
    samplerDescriptor.magFilter = MTLSamplerMinMagFilterNearest;
    if (imageFlags & NVG_IMAGE_GENERATE_MIPMAPS)
      samplerDescriptor.mipFilter = MTLSamplerMipFilterNearest;
  } else {
    samplerDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
    if (imageFlags & NVG_IMAGE_GENERATE_MIPMAPS)
      samplerDescriptor.mipFilter = MTLSamplerMipFilterLinear;
  }

  if (imageFlags & NVG_IMAGE_REPEATX) {
    samplerDescriptor.sAddressMode = MTLSamplerAddressModeRepeat;
  } else {
    samplerDescriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
  }

  if (imageFlags & NVG_IMAGE_REPEATY) {
    samplerDescriptor.tAddressMode = MTLSamplerAddressModeRepeat;
  } else {
    samplerDescriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
  }

  tex->sampler = [mtl->metalLayer.device
      newSamplerStateWithDescriptor:samplerDescriptor];
  [samplerDescriptor release];

  return tex->id;
}

static void mtlnvg__renderDelete(void* uptr) {
  MNVGcontext* mtl = (MNVGcontext*)uptr;

  [mtl->commandQueue release];
  [mtl->defaultStencilState release];
  [mtl->fragmentFunction release];
  [mtl->vertexDescriptor release];
  [mtl->vertexFunction release];
  [mtl->fillShapeStencilState release];
  [mtl->fillAntiAliasStencilState release];
  [mtl->fillStencilState release];
  [mtl->strokeShapeStencilState release];
  [mtl->strokeAntiAliasStencilState release];
  [mtl->strokeClearStencilState release];

  if (mtl->stencilTexture) {
    [mtl->stencilTexture release];
    mtl->stencilTexture = nil;
  }
}

static int mtlnvg__renderDeleteTexture(void* uptr, int image) {
  MNVGcontext* mtl = (MNVGcontext*)uptr;
  for (int i = 0; i < mtl->ntextures; i++) {
    if (mtl->textures[i].id == image) {
      if (mtl->textures[i].tex != nil &&
          (mtl->textures[i].flags & NVG_IMAGE_NODELETE) == 0) {
        [mtl->textures[i].tex release];
        [mtl->textures[i].sampler release];
      }
      memset(&mtl->textures[i], 0, sizeof(MNVGtexture));
      return 1;
    }
  }
  return 0;
}

static void mtlnvg__renderFill(void* uptr, NVGpaint* paint,
                              NVGcompositeOperationState compositeOperation,
                              NVGscissor* scissor, float fringe,
                              const float* bounds, const NVGpath* paths,
                              int npaths) {
  MNVGcontext* mtl = (MNVGcontext*)uptr;
  MNVGcall* call = mtlnvg__allocCall(mtl);
  NVGvertex* quad;
  int i, maxindexes, maxverts, indexOffset, vertOffset, hubVertOffset;

  if (call == NULL) return;

  call->type = MNVG_FILL;
  call->triangleCount = 4;
  call->pathOffset = mtlnvg__allocPaths(mtl, npaths);
  if (call->pathOffset == -1) goto error;
  call->pathCount = npaths;
  call->image = paint->image;
  call->blendFunc = mtlnvg__blendCompositeOperation(compositeOperation);

  if (npaths == 1 && paths[0].convex)
  {
    call->type = MNVG_CONVEXFILL;
    call->triangleCount = 0;  // Bounding box fill quad not needed for convex fill
  }

  // Allocate vertices for all the paths.
  maxverts = mtlnvg__maxVertCount(paths, npaths, &maxindexes)
             + call->triangleCount;
  vertOffset = mtlnvg__allocVerts(mtl, maxverts);
  if (vertOffset == -1) goto error;

  indexOffset = mtlnvg__allocIndexes(mtl, maxindexes);
  if (indexOffset == -1) goto error;
  call->indexOffset = indexOffset;
  call->indexCount = maxindexes;
  uint16_t* index = &mtl->indexes[indexOffset];

  for (i = 0; i < npaths; i++) {
    MNVGpath* copy = &mtl->paths[call->pathOffset + i];
    const NVGpath* path = &paths[i];
    memset(copy, 0, sizeof(MNVGpath));
    if (path->nfill > 0) {
      copy->fillOffset = vertOffset;
      copy->fillCount = path->nfill;
      memcpy(&mtl->verts[vertOffset], path->fill,
             sizeof(NVGvertex) * path->nfill);

      hubVertOffset = vertOffset++;
      for (int j = 2; j < path->nfill; j++) {
        *index++ = hubVertOffset;
        *index++ = vertOffset++;
        *index++ = vertOffset;
      }
      vertOffset++;
    }
    if (path->nstroke > 0) {
      copy->strokeOffset = vertOffset;
      copy->strokeCount = path->nstroke;
      memcpy(&mtl->verts[vertOffset], path->stroke,
             sizeof(NVGvertex) * path->nstroke);
      vertOffset += path->nstroke;
    }
  }

  // Setup uniforms for draw calls
  if (call->type == MNVG_FILL) {
    // Quad
    call->triangleOffset = vertOffset;
    quad = &mtl->verts[call->triangleOffset];
    mtlnvg__vset(&quad[0], bounds[2], bounds[3], 0.5f, 1.0f);
    mtlnvg__vset(&quad[1], bounds[2], bounds[1], 0.5f, 1.0f);
    mtlnvg__vset(&quad[2], bounds[0], bounds[3], 0.5f, 1.0f);
    mtlnvg__vset(&quad[3], bounds[0], bounds[1], 0.5f, 1.0f);
  }

  // Fill shader
  call->uniformOffset = mtlnvg__allocFragUniforms(mtl, 1);
  if (call->uniformOffset == -1) goto error;
  mtlnvg__convertPaint(mtl, mtlnvg__fragUniformPtr(mtl, call->uniformOffset),
                       paint, scissor, fringe, fringe, -1.0f);

  return;

error:
  // We get here if call alloc was ok, but something else is not.
  // Roll back the last call to prevent drawing it.
  if (mtl->ncalls > 0) mtl->ncalls--;
}

static void mtlnvg__renderFlush(void* uptr) {
  MNVGcontext* mtl = (MNVGcontext*)uptr;

  // Updates stencil texture whenever viewport size shrinks.
  if (mtl->stencilTexture != nil &&
      (mtl->stencilTexture.width < mtl->viewPortSize.x ||
       mtl->stencilTexture.height < mtl->viewPortSize.y)) {
    [mtl->stencilTexture release];
    mtl->stencilTexture = nil;
  }
  if (mtl->stencilTexture == nil) {
    MTLTextureDescriptor *stencilTextureDescriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8
        width:mtl->viewPortSize.x
        height:mtl->viewPortSize.y
        mipmapped:NO];
    mtl->stencilTexture = [mtl->metalLayer.device
        newTextureWithDescriptor:stencilTextureDescriptor];
  }

  // Submits commands.
  mtl->commandBuffer = [mtl->commandQueue commandBuffer];
  mtl->drawable = mtl->metalLayer.nextDrawable;
  mtl->renderEncoder = mtlnvg__renderCommandEncoder(mtl);
  @autoreleasepool {
    for (int i = 0; i < mtl->ncalls; i++) {
      MNVGcall* call = &mtl->calls[i];

      MNVGblend* blend = &call->blendFunc;
      mtlnvg__updateRenderPipelineStates(mtl, blend);

      if (call->type == MNVG_FILL)
        mtlnvg__fill(mtl, call);
      else if (call->type == MNVG_CONVEXFILL)
        mtlnvg__convexFill(mtl, call);
      else if (call->type == MNVG_STROKE)
        mtlnvg__stroke(mtl, call);
      else if (call->type == MNVG_TRIANGLES)
        mtlnvg__triangles(mtl, call);
    }
  }

  [mtl->renderEncoder endEncoding];
  [mtl->commandBuffer presentDrawable:mtl->drawable];
  mtl->drawable = nil;

  [mtl->commandBuffer commit];
  [mtl->commandBuffer waitUntilCompleted];

  mtl->nindexes = 0;
  mtl->nverts = 0;
  mtl->npaths = 0;
  mtl->ncalls = 0;
  mtl->nuniforms = 0;
}

static int mtlnvg__renderGetTextureSize(void* uptr, int image, int* w, int* h) {
  MNVGcontext* mtl = (MNVGcontext*)uptr;
  MNVGtexture* tex = mtlnvg__findTexture(mtl, image);
  if (tex == NULL) return 0;
  *w = tex->tex.width;
  *h = tex->tex.height;
  return 1;
}

static void mtlnvg__renderStroke(void* uptr, NVGpaint* paint,
                                 NVGcompositeOperationState compositeOperation,
                                 NVGscissor* scissor, float fringe,
                                 float strokeWidth, const NVGpath* paths,
                                 int npaths) {
  MNVGcontext* mtl = (MNVGcontext*)uptr;
  MNVGcall* call = mtlnvg__allocCall(mtl);
  int i, maxverts, offset;

  if (call == NULL) return;

  call->type = MNVG_STROKE;
  call->pathOffset = mtlnvg__allocPaths(mtl, npaths);
  if (call->pathOffset == -1) goto error;
  call->pathCount = npaths;
  call->image = paint->image;
  call->blendFunc = mtlnvg__blendCompositeOperation(compositeOperation);

  // Allocate vertices for all the paths.
  maxverts = mtlnvg__maxVertCount(paths, npaths, NULL);
  offset = mtlnvg__allocVerts(mtl, maxverts);
  if (offset == -1) goto error;

  for (i = 0; i < npaths; i++) {
    MNVGpath* copy = &mtl->paths[call->pathOffset + i];
    const NVGpath* path = &paths[i];
    memset(copy, 0, sizeof(MNVGpath));
    if (path->nstroke > 0) {
      copy->strokeOffset = offset;
      copy->strokeCount = path->nstroke;
      memcpy(&mtl->verts[offset], path->stroke,
             sizeof(NVGvertex) * path->nstroke);
      offset += path->nstroke;
    }
  }

  if (mtl->flags & NVG_STENCIL_STROKES) {
    // Fill shader
    call->uniformOffset = mtlnvg__allocFragUniforms(mtl, 2);
    if (call->uniformOffset == -1) goto error;
    mtlnvg__convertPaint(mtl, mtlnvg__fragUniformPtr(mtl, call->uniformOffset),
                         paint, scissor, strokeWidth, fringe, -1.0f);
    MNVGfragUniforms* frag = \
        mtlnvg__fragUniformPtr(mtl, call->uniformOffset + mtl->fragSize);
    mtlnvg__convertPaint(mtl, frag, paint, scissor, strokeWidth, fringe,
                         1.0f - 0.5f / 255.0f);
  } else {
    // Fill shader
    call->uniformOffset = mtlnvg__allocFragUniforms(mtl, 1);
    if (call->uniformOffset == -1) goto error;
    mtlnvg__convertPaint(mtl, mtlnvg__fragUniformPtr(mtl, call->uniformOffset),
                         paint, scissor, strokeWidth, fringe, -1.0f);
  }

  return;

error:
  // We get here if call alloc was ok, but something else is not.
  // Roll back the last call to prevent drawing it.
  if (mtl->ncalls > 0) mtl->ncalls--;
}

static void mtlnvg__renderTriangles(
    void* uptr, NVGpaint* paint, NVGcompositeOperationState compositeOperation,
    NVGscissor* scissor, const NVGvertex* verts, int nverts) {
  MNVGcontext* mtl = (MNVGcontext*)uptr;
  MNVGcall* call = mtlnvg__allocCall(mtl);
  MNVGfragUniforms* frag;

  if (call == NULL) return;

  call->type = MNVG_TRIANGLES;
  call->image = paint->image;
  call->blendFunc = mtlnvg__blendCompositeOperation(compositeOperation);

  // Allocate vertices for all the paths.
  call->triangleOffset = mtlnvg__allocVerts(mtl, nverts);
  if (call->triangleOffset == -1) goto error;
  call->triangleCount = nverts;

  memcpy(&mtl->verts[call->triangleOffset], verts, sizeof(NVGvertex) * nverts);

  // Fill shader
  call->uniformOffset = mtlnvg__allocFragUniforms(mtl, 1);
  if (call->uniformOffset == -1) goto error;
  frag = mtlnvg__fragUniformPtr(mtl, call->uniformOffset);
  mtlnvg__convertPaint(mtl, frag, paint, scissor, 1.0f, 1.0f, -1.0f);
  frag->type = MNVG_SHADER_IMG;

  return;

error:
  // We get here if call alloc was ok, but something else is not.
  // Roll back the last call to prevent drawing it.
  if (mtl->ncalls > 0) mtl->ncalls--;
}

static int mtlnvg__renderUpdateTexture(void* uptr, int image, int x, int y,
                                       int w, int h,
                                       const unsigned char* data) {
  MNVGcontext* mtl = (MNVGcontext*)uptr;
  MNVGtexture* tex = mtlnvg__findTexture(mtl, image);

  if (tex == NULL) return 0;
  id<MTLTexture> texture = tex->tex;

  unsigned char* bytes;
  NSUInteger bytesPerRow;
  if (tex->type == NVG_TEXTURE_RGBA) {
    bytesPerRow = tex->tex.width * 4;
    bytes = (unsigned char*)data + y * bytesPerRow + x * 4;
  } else {
    bytesPerRow = tex->tex.width;
    bytes = (unsigned char*)data + y * bytesPerRow + x;
  }
  [texture replaceRegion:MTLRegionMake2D(x, y, w, h)
             mipmapLevel:0
               withBytes:bytes
             bytesPerRow:bytesPerRow];

  return 1;
}

static void mtlnvg__renderViewport(void* uptr, int width, int height,
                                   float devicePixelRatio) {
  MNVGcontext* mtl = (MNVGcontext*)uptr;
  mtl->devicePixelRatio = devicePixelRatio;
  mtl->viewPortSize = (vector_uint2){width * devicePixelRatio,
                                     height * devicePixelRatio};

  // Initializes view size buffer for vertex function.
  if (mtl->viewSizeBuffer == nil) {
    mtl->viewSizeBuffer = [mtl->metalLayer.device
        newBufferWithLength:sizeof(vector_float2)
        options:kMetalBufferOptions];
  }
  float* viewSize = (float*)[mtl->viewSizeBuffer contents];
  viewSize[0] = width;
  viewSize[1] = height;
}

NVGcontext* nvgCreateMTL(void* metalLayer, int flags) {
#if TARGET_OS_SIMULATOR == 1
  printf("Metal is not supported for iPhone Simulator.\n");
  return NULL;
#elif defined(MNVG_INVALID_TARGET)
  printf("Metal is only supported on iOS, macOS, and tvOS.\n");
  return NULL;
#endif

  NVGparams params;
  NVGcontext* ctx = NULL;
  MNVGcontext* mtl = (MNVGcontext *)malloc(sizeof(MNVGcontext));
  if (mtl == NULL) goto error;
  memset(mtl, 0, sizeof(MNVGcontext));

  memset(&params, 0, sizeof(params));
  params.renderCreate = mtlnvg__renderCreate;
  params.renderCreateTexture = mtlnvg__renderCreateTexture;
  params.renderDeleteTexture = mtlnvg__renderDeleteTexture;
  params.renderUpdateTexture = mtlnvg__renderUpdateTexture;
  params.renderGetTextureSize = mtlnvg__renderGetTextureSize;
  params.renderViewport = mtlnvg__renderViewport;
  params.renderCancel = mtlnvg__renderCancel;
  params.renderFlush = mtlnvg__renderFlush;
  params.renderFill = mtlnvg__renderFill;
  params.renderStroke = mtlnvg__renderStroke;
  params.renderTriangles = mtlnvg__renderTriangles;
  params.renderDelete = mtlnvg__renderDelete;
  params.userPtr = mtl;
  params.edgeAntiAlias = flags & NVG_ANTIALIAS ? 1 : 0;

  mtl->flags = flags;
  mtl->fragSize = sizeof(MNVGfragUniforms);
  mtl->indexSize = 2;  // MTLIndexTypeUInt16
  mtl->metalLayer = (__bridge CAMetalLayer*)metalLayer;

  ctx = nvgCreateInternal(&params);
  if (ctx == NULL) goto error;
  return ctx;

error:
  // 'mtl' is freed by nvgDeleteInternal.
  if (ctx != NULL) nvgDeleteInternal(ctx);
  return NULL;
}

void nvgDeleteMTL(NVGcontext* ctx) {
  nvgDeleteInternal(ctx);
}