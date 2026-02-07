# Reify - 2D Graphics Rendering on GPU

## Init font_msdf_gen

### Nested Dependencies

- cmake, C++ compiler, FreeType dev, libpng dev

### Commands

`git submodule update --init --recursive`
`cmake -S lib/msdfgen -B lib/msdfgen/build -DMSDFGEN_CORE_ONLY=OFF -DMSDFGEN_USE_VCPKG=OFF -DMSDFGEN_DISABLE_SVG=ON -DMSDFGEN_USE_SKIA=OFF -DCMAKE_BUILD_TYPE=Release && cmake --build lib/msdfgen/build --config Release -j`
