import { $ } from "bun";

await $`cargo update`;

let vendor_path = await createTempDir("siap-dev-vendor");
let home_path = await createTempDir("siap-dev-home");
const cargo_config = await $`CARGO_HOME=${home_path} cargo vendor --locked ${vendor_path}`.text();
const nix_hash = (await $`nix hash path ${vendor_path} --type sha256`.text()).trim();
const cargo_lock = (await $`sha256sum Cargo.lock`.text()).split(" ")[0];
let hashes_conent = `deps = "${nix_hash}"
cargo_config = '''${cargo_config}'''
cargo_lock = "${cargo_lock}"`;

await Bun.write("./hashes.toml", hashes_conent);

await $`rm -r ${home_path}`;
await $`rm -r ${vendor_path}`;

async function createTempDir(prefix) {
  const path = `${process.env.TMP || "/tmp"}/${prefix}-${crypto.randomUUID()}`;

  await $`mkdir -p ${path}`;
  return path;
}