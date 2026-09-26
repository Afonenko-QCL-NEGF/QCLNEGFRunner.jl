// Typed process orchestration. Subprocess arguments never pass through a shell.
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("../", import.meta.url));
const julia = Deno.env.get("JULIA") ?? "julia";
const environment = Deno.env.get("QCL_NEGF_PROJECT");
async function run(args: string[], env: Record<string, string> = {}) {
  const status = await new Deno.Command(julia, {
    args: ["--startup-file=no", ...args],
    cwd: root,
    env: { JULIA_NUM_PRECOMPILE_TASKS: "2", OPENBLAS_NUM_THREADS: "1", ...env },
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  }).spawn().status;
  if (!status.success) throw new Error(`Julia failed with exit ${status.code}`);
}
const command = Deno.args[0] ?? "test";
switch (command) {
  case "test":
    if (environment) {
      await run([
        "--threads=2",
        "--check-bounds=yes",
        `--project=${environment}`,
        "test/runtests.jl",
        ...Deno.args.slice(1),
      ]);
    } else {
      await run([
        "--project=.",
        "-e",
        'using Pkg; Pkg.instantiate(); Pkg.test(; julia_args=["--threads=2", "--check-bounds=yes"], test_args=ARGS)',
        ...Deno.args.slice(1),
      ]);
    }
    break;
  case "docs":
    if (!environment) await run(["--project=docs", "-e", "using Pkg; Pkg.instantiate()"]);
    await run([`--project=${environment ?? "docs"}`, "docs/make.jl"]);
    break;
  case "prepare-depot": {
    const [project, depot] = Deno.args.slice(1);
    if (!project?.startsWith("/") || !depot?.startsWith("/")) {
      throw new Error("prepare-depot requires an absolute prepared environment and empty depot");
    }
    await Deno.mkdir(depot, { recursive: true });
    for await (const _entry of Deno.readDir(depot)) {
      throw new Error("Dependency depot must be empty");
    }
    const before = await Deno.readFile(`${project}/Manifest.toml`);
    await run([`--project=${project}`, "-e", "using Pkg; Pkg.instantiate()"], {
      JULIA_DEPOT_PATH: depot,
      JULIA_CPU_TARGET: "generic",
      JULIA_PKG_PRECOMPILE_AUTO: "0",
    });
    const after = await Deno.readFile(`${project}/Manifest.toml`);
    if (before.length !== after.length || before.some((value, index) => value !== after[index])) {
      throw new Error("Dependency preparation changed the committed native manifest");
    }
    for (const name of ["compiled", "logs", "registries", "scratchspaces"]) {
      try {
        await Deno.remove(`${depot}/${name}`, { recursive: true });
      } catch (error) {
        if (!(error instanceof Deno.errors.NotFound)) throw error;
      }
    }
    break;
  }
  default:
    throw new Error(`Unknown task: ${command}`);
}
