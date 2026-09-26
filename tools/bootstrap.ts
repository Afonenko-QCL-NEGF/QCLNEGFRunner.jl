// Exact, checksum-verified Julia runtime for a trusted Linux x64 runner.
if (Deno.build.os !== "linux" || Deno.build.arch !== "x86_64") {
  throw new Error("This pinned runtime supports Linux x86_64");
}
const root = new URL("../", import.meta.url).pathname.replace(/\/$/, "");
const path = `${root}/.build/julia`;
const response = await fetch(
  "https://julialang-s3.julialang.org/bin/linux/x64/1.13/julia-1.13.0-linux-x86_64.tar.gz",
);
if (!response.ok) throw new Error(`Julia download failed: ${response.status}`);
const bytes = new Uint8Array(await response.arrayBuffer());
const digest = await crypto.subtle.digest("SHA-256", bytes);
const sha256 = Array.from(new Uint8Array(digest), (x) => x.toString(16).padStart(2, "0")).join("");
if (sha256 !== "8975da61c128a5e5ded3e719e868da8c8781deb7ad7913d37fb99be02a81904b") {
  throw new Error("Julia download checksum mismatch");
}
await Deno.mkdir(path, { recursive: true });
const archive = `${root}/.build/julia.tar.gz`;
await Deno.writeFile(archive, bytes);
const status = await new Deno.Command("tar", {
  args: ["-xzf", archive, "-C", path, "--strip-components=1"],
  stdout: "inherit",
  stderr: "inherit",
}).spawn().status;
if (!status.success) throw new Error("Julia extraction failed");
console.log(`${path}/bin/julia`);
