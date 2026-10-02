import { fileURLToPath } from "node:url";

const preparation = fileURLToPath(new URL("./ci.ts", import.meta.url));
const registry = 'name = "General"\nuuid = "23338594-aafe-5451-b93e-139f81909106"\n';

function assert(condition: boolean, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function prepare(project: string, depot: string, julia: string) {
  return await new Deno.Command(Deno.execPath(), {
    args: [
      "run",
      "--allow-read",
      "--allow-write",
      "--allow-env",
      "--allow-run",
      preparation,
      "prepare-depot",
      project,
      depot,
    ],
    env: { JULIA: julia },
    stdout: "piped",
    stderr: "piped",
  }).output();
}

Deno.test("prepared depot retains frozen registry and package bytes while removing transient data", async () => {
  const directory = await Deno.makeTempDir({ prefix: "qcl-prepared-depot-" });
  try {
    const project = `${directory}/project`, depot = `${directory}/depot`;
    await Deno.mkdir(project);
    const manifest = 'julia_version = "1.13.0"\nmanifest_format = "2.1"\n';
    await Deno.writeTextFile(`${project}/Manifest.toml`, manifest);
    const julia = `${directory}/fake-julia`;
    // Exercise the real Deno preparation path with a successful package-manager
    // boundary. No Julia interpreter, package download or solver runs in this test.
    await Deno.writeTextFile(
      julia,
      `#!/bin/sh
set -eu
mkdir -p "$JULIA_DEPOT_PATH/registries/General" "$JULIA_DEPOT_PATH/packages/Example/frozen" "$JULIA_DEPOT_PATH/artifacts/frozen"
for name in compiled logs scratchspaces; do
  mkdir -p "$JULIA_DEPOT_PATH/$name"
  printf 'transient' > "$JULIA_DEPOT_PATH/$name/cache"
done
printf 'name = "General"\\nuuid = "23338594-aafe-5451-b93e-139f81909106"\\n' > "$JULIA_DEPOT_PATH/registries/General/Registry.toml"
printf 'pinned package bytes' > "$JULIA_DEPOT_PATH/packages/Example/frozen/source.jl"
printf 'pinned artifact bytes' > "$JULIA_DEPOT_PATH/artifacts/frozen/library"
`,
    );
    await Deno.chmod(julia, 0o700);
    const result = await prepare(project, depot, julia);
    assert(result.success, new TextDecoder().decode(result.stderr));
    assert(await Deno.readTextFile(`${project}/Manifest.toml`) === manifest, "Manifest changed");
    assert(
      await Deno.readTextFile(`${depot}/registries/General/Registry.toml`) === registry,
      "Prepared depot lost or changed its captured registry",
    );
    assert(
      await Deno.readTextFile(`${depot}/packages/Example/frozen/source.jl`) ===
        "pinned package bytes",
      "Prepared depot changed its captured package",
    );
    assert(
      await Deno.readTextFile(`${depot}/artifacts/frozen/library`) === "pinned artifact bytes",
      "Prepared depot changed its captured artifact",
    );
    const names = new Set<string>();
    for await (const entry of Deno.readDir(depot)) names.add(entry.name);
    assert(
      !["compiled", "logs", "scratchspaces"].some((name) => names.has(name)),
      "Transient data retained",
    );
  } finally {
    await Deno.remove(directory, { recursive: true });
  }
});

Deno.test("preparation refuses to replace an existing frozen depot", async () => {
  const directory = await Deno.makeTempDir({ prefix: "qcl-prepared-depot-" });
  try {
    const depot = `${directory}/depot`;
    await Deno.mkdir(depot);
    await Deno.writeTextFile(`${depot}/retained`, "original bytes");
    const result = await prepare(directory, depot, `${directory}/missing-julia`);
    assert(!result.success, "Existing depot was accepted");
    assert(
      new TextDecoder().decode(result.stderr).includes("must be empty"),
      "Wrong failure boundary",
    );
    assert(
      await Deno.readTextFile(`${depot}/retained`) === "original bytes",
      "Existing depot changed",
    );
  } finally {
    await Deno.remove(directory, { recursive: true });
  }
});
