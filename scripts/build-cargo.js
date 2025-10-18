import { $ } from "bun";
import { env } from "process";
import { parseArgs } from "util";
import { stat } from 'node:fs/promises';

env.PATH = env.buildInputs.split(" ").map(p => `${p}/bin`).join(":");

const { values } = parseArgs({
  args: Bun.argv,
  options: {
    source: {
      type: 'string',
    },
    dependencies: {
      type: 'string',
    },
    package: {
      type: 'string',
    },
  },
  strict: true,
  allowPositionals: true,
});

const cargo_target = `${env.out}/cargo_target`;
const cargo_home = `${env.out}/cargo_home`;

await $`mkdir -p ${cargo_home}`;

const cargo_config_content = `[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "${values.dependencies}"`;
await Bun.write(`${cargo_home}/config.toml`, cargo_config_content);

await $`mkdir -p ${cargo_target}`;
await $`mkdir -p ${env.out}/bin`;
$.cwd(values.source).env({
  PATH: env.PATH,
  CARGO_HOME: cargo_home,
  CARGO_TARGET_DIR: cargo_target,
});

// Must use which to find cargo, because env.PATH is not picked up otherwise (https://github.com/oven-sh/bun/issues/9747)
await $`$(which cargo) build --release -p ${values.package} --offline --frozen --verbose`;
await $`$(which cp) ${cargo_target}/release/${values.package} ${env.out}/bin/${values.package}`;

try {
  await $`rm -r ${cargo_home}`;
} catch (e) {
  console.log("Failed to remove cargo home (sometime the directory is not created):", e);
}

await $`rm -r ${cargo_target}`;