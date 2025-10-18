import { $ } from "bun";
import { env } from "process";
import { parseArgs } from "util";

env.PATH = env.buildInputs.split(" ").map(p => `${p}/bin`).join(":");// + ":" + env.PATH;

// await Bun.write(`${env.out}/env.txt`, JSON.stringify(env, null, 2));

const { values } = parseArgs({
  args: Bun.argv,
  options: {
    source: {
      type: 'string',
    },
  },
  strict: true,
  allowPositionals: true,
});

console.log("Path: ", env.PATH);

$.cwd(values.source).env({
  PATH: env.PATH,
  CARGO_HOME: env.TMP,
});
// await $`CARGO_HOME=${env.TMP} cargo vendor ${env.out} --locked`;
await $`$(which cargo) vendor ${env.out} --locked`;