{
  apple-sdk,
  callPackage,
  darwin,
  git,
  lib,
  llvmPackages,
  pkg-config,
  runCommand,
  stdenv,
  testers,
  versionCheckHook,
  writableTmpDirAsHomeHook,
  xcbuild,
  zig_0_15,
  revision ? "dirty",
  optimize ? "Debug",
  simd ? true,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "libghostty-vt";
  version = "0.1.0-dev+${revision}-nix";

  # We limit source like this to try and reduce the amount of rebuilds as possible
  # thus we only provide the source that is needed for the build.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.intersection (lib.fileset.fromSource (lib.sources.cleanSource ../.)) (
      lib.fileset.unions [
        ../include
        ../pkg
        ../src
        ../vendor
        ../build.zig
        ../build.zig.zon
        ../build.zig.zon.nix
      ]
    );
  };

  deps = callPackage ../build.zig.zon.nix {name = "${finalAttrs.pname}-cache-${finalAttrs.version}";};

  # Zig's build runner computes *relative* paths from a dependency's
  # source directory (the Run-step CWD) back to the build artefacts in
  # .zig-cache.  The Nix dep-cache stores each dependency as a symlink
  # into /nix/store.  When the OS resolves the CWD through the symlink,
  # the relative ".." components land in a different directory tree than
  # the build runner expected — causing "FileNotFound" when it tries to
  # spawn the compiled code-generator binary.
  #
  # Fix: dereference symlinks so every entry is a real directory and
  # relative paths resolve correctly.
  depsDeref = runCommand "${finalAttrs.pname}-deps-deref-${finalAttrs.version}" {} ''
    cp -rL ${finalAttrs.deps}/ $out
  '';

  nativeBuildInputs =
    [
      git
      pkg-config
      writableTmpDirAsHomeHook
      zig_0_15
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      apple-sdk
      darwin.cctools # provides libtool for creating static fat archives
      xcbuild
    ];

  buildInputs = [];

  doCheck = false;
  dontSetZigDefaultFlags = true;

  zigBuildFlags = [
    "--system"
    "${finalAttrs.depsDeref}"
    "-Dlib-version-string=${finalAttrs.version}"
    "-Dcpu=baseline"
    "-Doptimize=${optimize}"
    "-Dapp-runtime=none"
    "-Demit-lib-vt=true"
    "-Dsimd=${lib.boolToString simd}"
    # Install headers directly into the `dev` output instead of letting
    # them land in $out/include and relying on nixpkgs's multi-output
    # fixup to relocate them. Because zig's pkg-config generator now
    # records the resolved include path in libghostty-vt.pc, installing
    # straight to $dev/include means the emitted `includedir=` is
    # already correct -- no postFixup rewrite needed.
    "--prefix-include-dir"
    "${placeholder "dev"}/include"
  ];
  zigCheckFlags = finalAttrs.zigBuildFlags ++ ["test-lib-vt"];

  outputs = [
    "out"
    "dev"
  ];

  # The zig build sets the dylib install name to @rpath/libghostty-vt.dylib,
  # which requires every consuming binary to embed a matching LC_RPATH.
  # Rewrite to the absolute path so the linker records it directly.
  postFixup = lib.optionalString stdenv.hostPlatform.isDarwin ''
    for dylib in "$out"/lib/libghostty-vt*.dylib; do
      if [ -f "$dylib" ] && ! [ -L "$dylib" ]; then
        install_name_tool -id "$dylib" "$dylib"
      fi
    done
  '';

  passthru.tests = {
    sanity-check = let
      version = "${lib.versions.major finalAttrs.version}.${lib.versions.minor finalAttrs.version}.${lib.versions.patch finalAttrs.version}";
    in
      runCommand "sanity-check" {} (builtins.concatStringsSep "\n" [
        ''
          ${lib.getExe' stdenv.cc "nm"} "${finalAttrs.finalPackage}/lib/libghostty-vt.so.${version}" | grep -q 'T ghostty_terminal_new'
          ${lib.getExe' stdenv.cc "nm"} "${finalAttrs.finalPackage}/lib/libghostty-vt.a" | grep -q 'T ghostty_terminal_new'
        ''
        (
          lib.optionalString simd
          ''
            ${lib.getExe' stdenv.cc "nm"} "${finalAttrs.finalPackage}/lib/libghostty-vt.a" | grep -q 'T .*simdutf'
            ${lib.getExe' stdenv.cc "nm"} "${finalAttrs.finalPackage}/lib/libghostty-vt.a" | grep -q 'T .*3hwy'
          ''
        )
        ''
          touch "$out"
        ''
      ]);
    pkg-config = testers.hasPkgConfigModules {
      package = finalAttrs.finalPackage.dev;
    };
    pkg-config-libs =
      runCommand "pkg-config-libs" {
        nativeBuildInputs = [pkg-config];
      } ''
        export PKG_CONFIG_PATH="${finalAttrs.finalPackage.dev}/share/pkgconfig"

        pkg-config --libs --static libghostty-vt | grep -q -- '-lghostty-vt'
        pkg-config --libs --static libghostty-vt-static | grep -q -- '${finalAttrs.finalPackage}/lib/libghostty-vt.a'

        touch "$out"
      '';
    build-with-shared = stdenv.mkDerivation {
      name = "build-with-shared";
      src = ./test-src;
      doInstallCheck = true;
      nativeBuildInputs = [pkg-config];
      buildInputs = [finalAttrs.finalPackage];
      buildPhase = ''
        runHook preBuildHooks

        cc -o test test_libghostty_vt.c \
          ''$(pkg-config --cflags --libs libghostty-vt)

        runHook postBuildHooks
      '';
      installPhase = ''
        runHook preInstallHooks

        mkdir -p "$out/bin";
        cp -a test "$out/bin/test";

        runHook postInstallHooks
      '';
      installCheckPhase = ''
        runHook preInstallCheckHooks

        "$out/bin/test" | grep -q "SIMD: ${
          if simd
          then "yes"
          else "no"
        }"
        ldd "$out/bin/test" 2>/dev/null | grep -q libghostty-vt

        runHook postInstallCheckHooks
      '';
      meta = {
        mainProgram = "test";
      };
    };
    build-with-static = stdenv.mkDerivation {
      name = "build-with-static";
      src = ./test-src;
      doInstallCheck = true;
      nativeBuildInputs = [pkg-config];
      buildInputs = [finalAttrs.finalPackage llvmPackages.libcxxClang];
      buildPhase = ''
        runHook preBuildHooks

        cc -o test test_libghostty_vt.c \
          ''$(pkg-config --cflags --libs --static libghostty-vt-static)

        runHook postBuildHooks
      '';
      installPhase = ''
        runHook preInstallHooks

        mkdir -p "$out/bin";
        cp -a test "$out/bin/test";

        runHook postInstallHooks
      '';
      installCheckPhase = ''
        runHook preInstallCheckHooks

        "$out/bin/test" | grep -q "SIMD: ${
          if simd
          then "yes"
          else "no"
        }"
        ! ldd "$out/bin/test" 2>/dev/null | grep -q libghostty-vt

        runHook postInstallCheckHooks
      '';
      meta = {
        mainProgram = "test";
      };
    };
    build-example-c-vt-build-info = stdenv.mkDerivation {
      name = "build-example-c-vt-build-info";
      version = finalAttrs.version;
      src = ../example/c-vt-build-info/src;
      doInstallCheck = true;
      nativeBuildInputs = [pkg-config];
      nativeInstallCheckInputs = [versionCheckHook];
      buildInputs = [finalAttrs.finalPackage];
      buildPhase = ''
        runHook preBuildHooks

        cc -o test main.c \
          ''$(pkg-config --cflags --libs libghostty-vt)

        runHook postBuildHooks
      '';
      installPhase = ''
        runHook preInstallHooks

        mkdir -p "$out/bin";
        cp -a test "$out/bin/test";

        runHook postInstallHooks
      '';
      installCheckPhase = ''
        runHook preInstallCheckHooks

        ldd "$out/bin/test" 2>/dev/null | grep -q libghostty-vt

        runHook postInstallCheckHooks
      '';
      meta = {
        mainProgram = "test";
      };
    };
  };

  meta = {
    homepage = "https://ghostty.org";
    license = lib.licenses.mit;
    platforms = zig_0_15.meta.platforms;
    pkgConfigModules = [
      "libghostty-vt"
      "libghostty-vt-static"
    ];
  };
})
