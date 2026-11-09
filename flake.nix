{
  description = "mxl streamer";
  inputs = {
    nixpkgs = {
    };
    jpegxs-cuda = {
      url = "git+ssh://git@ssh.bitbucket.org/riedelcommunications/jxs-cuda.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    mxl = {
      url = "github:jonasohland/mxl/nix/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    gst-v210-cudaconvert = {
      url = "github:jonasohland/gst-v210-cudaconvert";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # rtpjxsvpay/rtpjxsvdepay and udpsrc2/udpsink2 are only on main so far.
    gst-plugins-rs = {
      url = "git+https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs.git?ref=main";
      flake = false;
    };
  };
  outputs =
    {
      self,
      nixpkgs,
      jpegxs-cuda,
      mxl,
      gst-plugins-rs,
      gst-v210-cudaconvert,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" ];
      forAllSystems =
        f:
        lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              config.allowUnfree = true; # CUDA
              overlays = [
                # The mxl overlay builds its Rust plugins with rust-bin.
                mxl.inputs.rust-overlay.overlays.default
                mxl.overlays.default
                jpegxs-cuda.overlays.default
                (final: prev: {
                  gst-plugins-rs-net = final.callPackage ./nix/gst-plugins-rs-net.nix {
                    src = gst-plugins-rs;
                    version = "0.16.0-unstable-${gst-plugins-rs.shortRev}";
                  };
                })
              ];
            }
          )
        );

      # The CUDA toolkits we build for. Only jxs-cuda and gst-cudav210 use CUDA;
      # GStreamer, mxl and the Rust plugins are the same for every toolkit.
      # cudav210 names the matching package in the gst-v210-cudaconvert flake.
      cudaVariants = pkgs: {
        cuda12 = {
          cudaPackages = pkgs.cudaPackages_12_9;
          cudav210 = "cuda12";
        };
        cuda13 = {
          cudaPackages = pkgs.cudaPackages_13;
          cudav210 = "cuda13";
        };
      };
      defaultCuda = "cuda13";

      # The packages, gst-env and dev shell for one CUDA toolkit.
      mkCudaSet =
        pkgs:
        { cudaPackages, cudav210 }:
        let
          inherit (pkgs.stdenv.hostPlatform) system;
          jxs-cuda = pkgs.jxs-cuda.override { inherit cudaPackages; };
          jxs-cuda-gstreamer = jxs-cuda.override { withGstreamer = true; };
          gst-cudav210 = gst-v210-cudaconvert.packages.${system}.${cudav210};

          # Every GStreamer plugin the streamer uses: mxlsrc/mxlsink, the
          # cudajxs encoder/decoder, cudav210pack/cudav210unpack,
          # rtpjxsv(de)pay, udpsrc2/udpsink2 and the common upstream plugins.
          gstPlugins = [
            pkgs.mxl
            pkgs.gst-plugins-mxl
            jxs-cuda-gstreamer
            gst-cudav210
            pkgs.gst-plugins-rs-net
          ]
          ++ pkgs.mxl.gstRuntimePlugins;
          gstPluginPath = lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" gstPlugins;

          # Nix programs look for the NVIDIA driver (libcuda.so.1) in
          # /run/opengl-driver/lib, which only NixOS has. On other distros
          # this links only the driver libraries into a cache directory and
          # puts it on LD_LIBRARY_PATH. Adding all of /usr/lib would mix the
          # host's glibc with Nix's.
          nvidiaDriverLibs = pkgs.writeText "nvidia-driver-libs.sh" ''
            if [ ! -e /run/opengl-driver/lib/libcuda.so.1 ]; then
              for d in /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu; do
                if [ -e "$d/libcuda.so.1" ]; then
                  driver_libs="''${XDG_CACHE_HOME:-$HOME/.cache}/mxl-streamer/driver-libs"
                  mkdir -p "$driver_libs"
                  ln -sf "$d"/libcuda.so* "$d"/libnvidia-*.so* "$d"/libnvcuvid.so* "$driver_libs/" 2>/dev/null
                  export LD_LIBRARY_PATH="$driver_libs''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                  unset driver_libs
                  break
                fi
              done
            fi
          '';
        in
        {
          packages = {
            inherit jxs-cuda jxs-cuda-gstreamer gst-cudav210;

            # gst-launch-1.0 and gst-inspect-1.0 with all plugins on the path.
            # GST_PLUGIN_PATH is searched before the system path, so a plugin
            # from a local build there would shadow the packaged one. The
            # wrappers clear it.
            gst-env = pkgs.symlinkJoin {
              name = "mxl-streamer-gst-env-cuda${cudaPackages.cudaMajorMinorVersion}";
              paths = [ pkgs.gst_all_1.gstreamer.bin ];
              nativeBuildInputs = [ pkgs.makeWrapper ];
              postBuild = ''
                for tool in "$out"/bin/gst-*; do
                  wrapProgram "$tool" \
                    --unset GST_PLUGIN_PATH \
                    --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "${gstPluginPath}" \
                    --run ". ${nvidiaDriverLibs}"
                done
              '';
              meta.mainProgram = "gst-launch-1.0";
            };
          };

          devShell = pkgs.mkShell.override { stdenv = cudaPackages.backendStdenv; } {
            packages = [
              pkgs.gst_all_1.gstreamer.bin
              pkgs.mxl
            ]
            ++ gstPlugins;

            # Clear GST_PLUGIN_PATH for the same reason as in gst-env.
            shellHook = ''
              unset GST_PLUGIN_PATH
              . ${nvidiaDriverLibs}
              export GST_PLUGIN_SYSTEM_PATH_1_0="${gstPluginPath}''${GST_PLUGIN_SYSTEM_PATH_1_0:+:$GST_PLUGIN_SYSTEM_PATH_1_0}"
            '';
          };
        };

      cudaSets = pkgs: lib.mapAttrs (_: mkCudaSet pkgs) (cudaVariants pkgs);
    in
    {
      # CUDA packages exist once per toolkit, e.g. gst-env-cuda12 and
      # gst-env-cuda13. The names without a suffix use the default toolkit.
      packages = forAllSystems (
        pkgs:
        let
          sets = cudaSets pkgs;
        in
        {
          inherit (pkgs)
            mxl
            gst-plugins-mxl
            gst-plugins-rs-net
            ;
        }
        // sets.${defaultCuda}.packages
        // lib.concatMapAttrs (
          cuda: set: lib.mapAttrs' (name: lib.nameValuePair "${name}-${cuda}") set.packages
        ) sets
      );

      devShells = forAllSystems (
        pkgs:
        let
          sets = cudaSets pkgs;
        in
        lib.mapAttrs (_: set: set.devShell) sets // { default = sets.${defaultCuda}.devShell; }
      );

      # nix flake check builds the plugins for every toolkit.
      checks = forAllSystems (
        pkgs:
        lib.concatMapAttrs (cuda: set: {
          "gst-env-${cuda}" = set.packages.gst-env;
          "devShell-${cuda}" = set.devShell;
        }) (cudaSets pkgs)
      );
    };
}
