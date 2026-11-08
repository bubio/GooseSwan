// GooseSwan test harness. Usage:
//   sst [v20] <case-file.json> [more files...]   SingleStepTests corpora
//   sst ws <rom> [suite] [fb|wav|fbwav]          headless ROM runner
//   sst run <rom> <frames> <out> [keys] [mono|color]  differential dump (see runner.goose)
//   sst mark <rom> <R|P>row:off,...             ws-test-suite pass/fail markers
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
    if argv[1] == "run" && argv.len > 4 {
        var frames: i64 = 0;
        let a = argv[3];
        for i in a.len { frames = frames * 10 + ((a[i] as i64) - 48); }
        core::run_diff(argv[2], frames, argv[4], if argv.len > 5 { argv[5] } else { "-" }, if argv.len > 6 { argv[6] } else { "" });
        return;
    }
    if argv[1] == "mark" && argv.len > 3 { core::run_mark(argv[2], argv[3]); return; }
    if argv[1] == "ppu_test" { core::ppu_test(); return; }
    if argv[1] == "apu_test" { core::apu_test(); return; }
    if argv[1] == "eeprom_test" { core::eeprom_test(); return; }
    var start: i64 = 1;
    if argv[1] == "v20" { core::cpu_v20 = true; start = 2; }
    for i in start..argv.len { core::run_file(argv[i]); }
}
