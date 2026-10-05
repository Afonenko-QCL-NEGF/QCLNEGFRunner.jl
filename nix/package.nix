# Native Julia manifest and Git submodule inputs are supplied by the root project.
{ pkgs, julia, preparedDepot, coreSrc, runnerSrc, environmentSrc, testProfile ? "production-build" }:
assert builtins.elem testProfile [ "production-build" "local-debug" ];
let caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "qcl-negf";
  version = "0.2.0";
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  # Pkg initializes LibGit2 even offline. stdenv's missing SSL_CERT_FILE must
  # not override a real, immutable CA bundle during cold Pkg precompilation.
  JULIA_SSL_CA_ROOTS_PATH = caBundle;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    runtime=$out/share/qcl-negf
    mkdir -p "$runtime/components" "$runtime/julia" $out/bin $out/share/depot
    cp -r ${coreSrc} "$runtime/components/QCLNEGF.jl"
    cp -r ${runnerSrc} "$runtime/components/QCLNEGFRunner.jl"
    cp ${environmentSrc}/Project.toml ${environmentSrc}/Manifest.toml "$runtime/julia/"
    chmod -R u+w "$runtime"
    export JULIA_DEPOT_PATH="$out/share/depot:${preparedDepot}"
    export JULIA_PKG_OFFLINE=true JULIA_CPU_TARGET=generic
    ${pkgs.lib.optionalString (testProfile == "production-build") ''
      case "$NIX_BUILD_CORES" in
        ""|*[!0-9]*|0) echo "A positive Nix build CPU allocation is required" >&2; exit 1 ;;
      esac
    ''}
    export JULIA_NUM_PRECOMPILE_TASKS=${if testProfile == "local-debug" then "2" else ''"$NIX_BUILD_CORES"''} OPENBLAS_NUM_THREADS=1
    ${julia}/bin/julia --startup-file=no --project="$runtime/julia" \
      -e 'using Pkg; Pkg.instantiate(; update_registry=false); using QCLNEGFRunner'
    makeWrapper ${julia}/bin/julia $out/bin/qcl-negf \
      --add-flags "--startup-file=no --project=$runtime/julia $runtime/components/QCLNEGFRunner.jl/scripts/scientific_workflow.jl" \
      --set JULIA_DEPOT_PATH "$out/share/depot:${preparedDepot}" \
      --set JULIA_PKG_OFFLINE true \
      --set JULIA_SSL_CA_ROOTS_PATH "${caBundle}" \
      --set OPENBLAS_NUM_THREADS 1
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/qcl-negf plan ${runnerSrc}/examples/config/operator-algebra.yaml --max-runs 1 > plan.json
  '';
  meta = {
    description = "QCL-NEGF scientific command-line runtime";
    license = pkgs.lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "qcl-negf";
  };
}
