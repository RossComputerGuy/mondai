{
  stdenv,
  zig,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "mondai";
  version = "0.1.0";

  nativeBuildInputs = [
    zig
    zig.hook
  ];
})
