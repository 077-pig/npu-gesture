transcript on

set tb_dir [file normalize [pwd]]
cd $tb_dir

if {[file isdirectory work]} {
    vdel -lib work -all
}
vlib work
vmap work work

set rtl_files [lsort [glob -nocomplain [file join $tb_dir .. G_RTL *.sv]]]
set tb_files  [lsort [glob -nocomplain [file join $tb_dir tb_*.sv]]]

if {[llength $rtl_files] == 0} {
    error "No RTL files found in ../G_RTL"
}
if {[llength $tb_files] == 0} {
    error "No testbench files found in TB"
}

puts "Compiling [llength $rtl_files] RTL files..."
eval vlog -sv $rtl_files

puts "Compiling [llength $tb_files] testbench files..."
eval vlog -sv $tb_files

puts "COMPILE PASS: [llength $rtl_files] RTL files and [llength $tb_files] testbenches"
