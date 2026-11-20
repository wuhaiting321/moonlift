const fs = require("fs");
const file = process.argv[2];
const calls = JSON.parse(process.argv[3]);
(async () => {
  const bytes = fs.readFileSync(file);
  const { instance } = await WebAssembly.instantiate(bytes, {});
  for (const [fn, args] of calls) {
    let out;
    try { out = instance.exports[fn](...args); } catch (e) { out = "trap:" + e.constructor.name; }
    console.log(fn + "(" + args.join(",") + ") = " + out);
  }
})();
