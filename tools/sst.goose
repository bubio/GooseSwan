// GooseSwan test harness. Usage:
//   sst [v20] <case-file.json> [more files...]   SingleStepTests corpora
//   sst ws <rom> [suite] [fb|wav|fbwav]          headless ROM runner
//   sst ppu_test | apu_test | eeprom_test        core self-tests
// Everything but main() lives in the files imported below; they are
// white-box tests in the core's own namespace.
import std;
import os;
import core from "../core";
import singlestep;
import runner;
import selftest_ppu;
import selftest_apu;
import selftest_eeprom;

fn main() {
    let argv = args();
    if argv.len < 2 { print("usage: sst [v20] <case-file.json> [more files...] | sst ws <rom.ws|wsc> | sst ppu_test|apu_test|eeprom_test"); exit(1); }
    if argv[1] == "ws" { core::run_ws(argv[2]); return; }
    if argv[1] == "ppu_test" { core::ppu_test(); return; }
    if argv[1] == "apu_test" { core::apu_test(); return; }
    if argv[1] == "eeprom_test" { core::eeprom_test(); return; }
    var start: i64 = 1;
    if argv[1] == "v20" { core::cpu_v20 = true; start = 2; }
    for i in start..argv.len { core::run_file(argv[i]); }
}
