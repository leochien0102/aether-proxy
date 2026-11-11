'use strict';
// M4-07: exercise the production budget arithmetic at a fractional-second boundary.
import * as fs from 'fs';

let source = fs.readfile(ARGV[0]);
let start = index(source, 'function budget_left()');
let end = index(source, '\nfunction run(', start);
let factory = loadstring('(function(clock, chain_deadline) { '
	+ substr(source, start, end - start) + ' return budget_left(); })')();
let now = () => [ 10, 500000000 ];
if (factory(now, 10.75) != 0.25 || factory(now, 10.25) != -0.25)
	die('fractional budget arithmetic extended the deadline');
print('PASS  M4-07 fractional monotonic budget never replenishes\n');
