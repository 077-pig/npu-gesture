transcript on

set tb_dir [file normalize [pwd]]
set tb_files [lsort [glob -nocomplain [file join $tb_dir tb_*.sv]]]

if {[llength $tb_files] == 0} {
    error "No testbench files found in TB"
}

set passed 0
set report [open [file join $tb_dir validation_results.txt] w]
foreach tb_file $tb_files {
    set top [file rootname [file tail $tb_file]]
    puts "=== RUN $top ==="

    if {[catch {vsim -voptargs=+acc work.$top} message]} {
        error "ELABORATION FAILED: $top: $message"
    }

    onfinish stop
    if {[catch {run -all} message]} {
        puts $report "FAIL $top: $message"
        close $report
        quit -sim
        error "SIMULATION FAILED: $top: $message"
    }

    set checked_pass [examine -radix unsigned sim:/$top/tb_passed]
    if {$checked_pass ne "1"} {
        puts $report "FAIL $top: checks did not complete successfully"
        close $report
        quit -sim
        error "SIMULATION FAILED: $top: tb_passed is not 1"
    }

    incr passed
    puts $report "PASS $top"
    flush $report
    quit -sim
}

puts $report "ALL TESTS PASSED: $passed/[llength $tb_files]"
close $report
puts "ALL TESTS PASSED: $passed/[llength $tb_files]"
