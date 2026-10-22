transcript on

if {![info exists TOP]} {
    set TOP tb_activation_skew_16
}

puts "=== RUN $TOP ==="
vsim -voptargs=+acc work.$TOP
onfinish stop
run -all
