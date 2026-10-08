// Keep scoped --allow-run=tar without inheriting loader injection variables.
export function extractArchive(archive: string, output: string): Promise<Deno.CommandStatus> {
  const path = Deno.env.get("PATH");
  if (!path) throw new Error("PATH is required for tar and gzip extraction");
  return new Deno.Command("tar", {
    args: ["-xzf", archive, "-C", output, "--strip-components=1"],
    clearEnv: true,
    env: { PATH: path },
    stdout: "inherit",
    stderr: "inherit",
  }).spawn().status;
}
