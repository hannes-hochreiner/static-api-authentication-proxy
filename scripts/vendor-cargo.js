import { $ } from "bun";
import { env } from "process";
import { parseArgs } from "util";

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

$.cwd(values.source).env({
  PATH: env.PATH,
  CARGO_HOME: env.TMP,
});
await $`cargo vendor ${env.out} --locked`;