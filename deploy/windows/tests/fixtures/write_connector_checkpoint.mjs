import { atomicWritePrivateFile } from "../../../../adapters/codex-connector/src/atomic-file.js";

const [target] = process.argv.slice(2);
if (!target) throw new Error("checkpoint path is required");
await atomicWritePrivateFile(target, '{"version":1}\n');
