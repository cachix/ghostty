{
  apple-sdk,
  callPackage,
  git,
  lib,
  llvmPackages,
  pkg-config,
  runCommand,
  stdenv,
  testers,
  versionCheckHook,
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

  nativeBuildInputs =
    [
      git
      pkg-config
      zig_0_15
    ]
    # On darwin the Zig build invokes `pkg/apple-sdk/addPaths`, which
    # normally shells out to `xcrun`/`xcode-select` to locate the active
    # SDK. Neither is available in the Nix sandbox, so we provide an
    # explicit SDK via `SDKROOT` (honored by the patched apple-sdk helper)
    # and add the SDK's store path as a build input so it participates in
    # hash inputs and runtime closure tracking.
    ++ lib.optional stdenv.hostPlatform.isDarwin apple-sdk;

  env = lib.optionalAttrs stdenv.hostPlatform.isDarwin {
    SDKROOT = "${apple-sdk}";
  };

  buildInputs = [];

  doCheck = false;
  dontSetZigDefaultFlags = true;

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
    "-Dlib-version-string=${finalAttrs.version}"
    "-Dcpu=baseline"
    "-Doptimize=${optimize}"
    "-Dapp-runtime=none"
    "-Demit-lib-vt=true"
    "-Dsimd=${lib.boolToString simd}"
  ];
  zigCheckFlags = finalAttrs.zigBuildFlags ++ ["test-lib-vt"];

  outputs = [
    "out"
    "dev"
  ];

  postInstall =
    ''
      mkdir -p "$dev/lib"
      mv "$out/lib/libghostty-vt.a" "$dev/lib"
      mv "$out/include" "$dev"
      mv "$out/share" "$dev"
    ''
    + lib.optionalString stdenv.hostPlatform.isLinux ''
      rm "$out/lib/libghostty-vt.so"
      ln -sf "$out/lib/libghostty-vt.so.${lib.versions.major finalAttrs.version}"  "$dev/lib/libghostty-vt.so"
    ''
    + lib.optionalString stdenv.hostPlatform.isDarwin ''
      # Zig's darwin install emits a versioned `libghostty-vt.<ver>.dylib`
      # plus an unversioned `libghostty-vt.dylib` symlink in $out/lib.
      # We want the build-time unversioned symlink to live in $dev so
      # consumers can link via `-lghostty-vt` without pulling $out into
      # their dev closure; remove $out's symlink and recreate an absolute
      # one in $dev pointing at the versioned file in $out.
      real=
      for f in "$out/lib"/libghostty-vt*.dylib; do
        if [ -e "$f" ] && [ ! -L "$f" ]; then
          real="$f"
          break
        fi
      done
      if [ -z "$real" ]; then
        echo "libghostty-vt: no versioned dylib found in $out/lib" >&2
        ls -la "$out/lib" >&2
        exit 1
      fi
      rm -f "$out/lib/libghostty-vt.dylib"
      ln -sf "$real" "$dev/lib/libghostty-vt.dylib"
    '';

  postFixup = ''
    substituteInPlace "$dev/share/pkgconfig/libghostty-vt.pc" \
      --replace-fail "$out" "$dev"
    substituteInPlace "$dev/share/pkgconfig/libghostty-vt-static.pc" \
      --replace-fail "$out" "$dev"
  '';

  passthru.tests = {
    sanity-check = let
      version = "${lib.versions.major finalAttrs.version}.${lib.versions.minor finalAttrs.version}.${lib.versions.patch finalAttrs.version}";
    in
      runCommand "sanity-check" {} (builtins.concatStringsSep "\n" [
        ''
          ${lib.getExe' stdenv.cc "nm"} "${finalAttrs.finalPackage}/lib/libghostty-vt.so.${version}" | grep -q 'T ghostty_terminal_new'
          ${lib.getExe' stdenv.cc "nm"} "${finalAttrs.finalPackage.dev}/lib/libghostty-vt.a" | grep -q 'T ghostty_terminal_new'
        ''
        (
          lib.optionalString simd
          ''
            ${lib.getExe' stdenv.cc "nm"} "${finalAttrs.finalPackage.dev}/lib/libghostty-vt.a" | grep -q 'T .*simdutf'
            ${lib.getExe' stdenv.cc "nm"} "${finalAttrs.finalPackage.dev}/lib/libghostty-vt.a" | grep -q 'T .*3hwy'
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
        pkg-config --libs --static libghostty-vt-static | grep -q -- '${finalAttrs.finalPackage.dev}/lib/libghostty-vt.a'

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
          ''$(pkg-config --cflags --libs libghostty-vt) \
          -Wl,-rpath,"${finalAttrs.finalPackage}/lib"

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
          ''$(pkg-config --cflags --libs libghostty-vt) \
          -Wl,-rpath,"${finalAttrs.finalPackage}/lib"

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
