transcript on

if {![info exists TOP]} {
    set TOP tb_activation_skew_16
}

puts "=== WAVE $TOP ==="
vsim -voptargs=+acc work.$TOP
add wave -r sim:/$TOP/*
onfinish stop
run -all
wave zoom full
