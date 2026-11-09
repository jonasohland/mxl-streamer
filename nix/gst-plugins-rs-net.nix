# The rtp and udp plugins from gst-plugins-rs main. They are not in a release
# yet and provide rtpjxsvpay/rtpjxsvdepay (rtp) and udpsrc2/udpsink2 (udp).
{
  lib,
  rustPlatform,
  pkg-config,
  gst_all_1,
  glib,
  src,
  version,
}:

let
  # Cargo.lock pins gtk-rs-core main at two commits: glib/gio at the newer one
  # and cairo/pango/graphene/gdk-pixbuf at an older one. The Nix cargo vendor
  # cannot hold one git source at two commits, so all crates use the newer one.
  # The crate versions are the same at both commits.
  gtkRsCoreOld = "gtk-rs-core?branch=main#0d766056fc087089632b836166d7b2a00b5f40d8";
  gtkRsCoreNew = "gtk-rs-core?branch=main#23d190c15f86f1c1e94d94815a286f5359768c2a";
  cargoLockContents = builtins.replaceStrings [ gtkRsCoreOld ] [ gtkRsCoreNew ] (
    builtins.readFile "${src}/Cargo.lock"
  );
in
rustPlatform.buildRustPackage {
  pname = "gst-plugins-rs-net";
  inherit src version;

  # The lock file pins gstreamer-rs, gtk-rs-core and others by git revision.
  cargoLock = {
    lockFileContents = cargoLockContents;
    allowBuiltinFetchGit = true;
  };

  postPatch = ''
    cp ${builtins.toFile "Cargo.lock" cargoLockContents} Cargo.lock
  '';

  cargoBuildFlags = [
    "-p"
    "gst-plugin-rtp"
    "-p"
    "gst-plugin-udp"
  ];

  nativeBuildInputs = [ pkg-config ];

  buildInputs = [
    glib
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
  ];

  # The tests need network access and a running GStreamer registry.
  doCheck = false;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/gstreamer-1.0"
    find target -path '*/release/libgstrs*.so' -maxdepth 3 \
      -exec install -m755 -t "$out/lib/gstreamer-1.0" {} +
    runHook postInstall
  '';

  meta = {
    description = "GStreamer rtp and udp plugins from gst-plugins-rs";
    homepage = "https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs";
    license = lib.licenses.mpl20;
    platforms = lib.platforms.linux;
  };
}
