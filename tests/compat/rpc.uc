'use strict';
// Load the frozen plugin exactly as rpcd does (docs/08 "更新接口（固定）").
// Only the executable path is redirected; forwarding and JSON parsing stay intact.
import * as fs from 'fs';

let methods = loadstring(fs.readfile(ARGV[0]))()?.aetherproxy;
let method = ARGV[1];
if (methods?.[method] == null)
	die(`unknown frozen method: ${method}`);
let args = json(ARGV[2]);
args.ubus_rpc_session = 'compat-session';
print(sprintf('%.J', methods[method].call({ args })), '\n');
