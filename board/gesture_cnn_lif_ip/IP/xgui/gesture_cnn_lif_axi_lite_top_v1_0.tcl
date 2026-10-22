# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "FC_ACC_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "FC_CLASS_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "FC_INPUT_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "FEATURE_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "FEATURE_DEPTH_WORDS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "QUANT_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "WEIGHT_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "WEIGHT_DEPTH_WORDS" -parent ${Page_0}


}

proc update_PARAM_VALUE.FC_ACC_WIDTH { PARAM_VALUE.FC_ACC_WIDTH } {
	# Procedure called to update FC_ACC_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FC_ACC_WIDTH { PARAM_VALUE.FC_ACC_WIDTH } {
	# Procedure called to validate FC_ACC_WIDTH
	return true
}

proc update_PARAM_VALUE.FC_CLASS_ADDR_WIDTH { PARAM_VALUE.FC_CLASS_ADDR_WIDTH } {
	# Procedure called to update FC_CLASS_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FC_CLASS_ADDR_WIDTH { PARAM_VALUE.FC_CLASS_ADDR_WIDTH } {
	# Procedure called to validate FC_CLASS_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.FC_INPUT_ADDR_WIDTH { PARAM_VALUE.FC_INPUT_ADDR_WIDTH } {
	# Procedure called to update FC_INPUT_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FC_INPUT_ADDR_WIDTH { PARAM_VALUE.FC_INPUT_ADDR_WIDTH } {
	# Procedure called to validate FC_INPUT_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.FEATURE_ADDR_WIDTH { PARAM_VALUE.FEATURE_ADDR_WIDTH } {
	# Procedure called to update FEATURE_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FEATURE_ADDR_WIDTH { PARAM_VALUE.FEATURE_ADDR_WIDTH } {
	# Procedure called to validate FEATURE_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.FEATURE_DEPTH_WORDS { PARAM_VALUE.FEATURE_DEPTH_WORDS } {
	# Procedure called to update FEATURE_DEPTH_WORDS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FEATURE_DEPTH_WORDS { PARAM_VALUE.FEATURE_DEPTH_WORDS } {
	# Procedure called to validate FEATURE_DEPTH_WORDS
	return true
}

proc update_PARAM_VALUE.QUANT_ADDR_WIDTH { PARAM_VALUE.QUANT_ADDR_WIDTH } {
	# Procedure called to update QUANT_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.QUANT_ADDR_WIDTH { PARAM_VALUE.QUANT_ADDR_WIDTH } {
	# Procedure called to validate QUANT_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.WEIGHT_ADDR_WIDTH { PARAM_VALUE.WEIGHT_ADDR_WIDTH } {
	# Procedure called to update WEIGHT_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.WEIGHT_ADDR_WIDTH { PARAM_VALUE.WEIGHT_ADDR_WIDTH } {
	# Procedure called to validate WEIGHT_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.WEIGHT_DEPTH_WORDS { PARAM_VALUE.WEIGHT_DEPTH_WORDS } {
	# Procedure called to update WEIGHT_DEPTH_WORDS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.WEIGHT_DEPTH_WORDS { PARAM_VALUE.WEIGHT_DEPTH_WORDS } {
	# Procedure called to validate WEIGHT_DEPTH_WORDS
	return true
}


proc update_MODELPARAM_VALUE.FEATURE_DEPTH_WORDS { MODELPARAM_VALUE.FEATURE_DEPTH_WORDS PARAM_VALUE.FEATURE_DEPTH_WORDS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FEATURE_DEPTH_WORDS}] ${MODELPARAM_VALUE.FEATURE_DEPTH_WORDS}
}

proc update_MODELPARAM_VALUE.FEATURE_ADDR_WIDTH { MODELPARAM_VALUE.FEATURE_ADDR_WIDTH PARAM_VALUE.FEATURE_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FEATURE_ADDR_WIDTH}] ${MODELPARAM_VALUE.FEATURE_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.WEIGHT_ADDR_WIDTH { MODELPARAM_VALUE.WEIGHT_ADDR_WIDTH PARAM_VALUE.WEIGHT_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.WEIGHT_ADDR_WIDTH}] ${MODELPARAM_VALUE.WEIGHT_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.WEIGHT_DEPTH_WORDS { MODELPARAM_VALUE.WEIGHT_DEPTH_WORDS PARAM_VALUE.WEIGHT_DEPTH_WORDS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.WEIGHT_DEPTH_WORDS}] ${MODELPARAM_VALUE.WEIGHT_DEPTH_WORDS}
}

proc update_MODELPARAM_VALUE.QUANT_ADDR_WIDTH { MODELPARAM_VALUE.QUANT_ADDR_WIDTH PARAM_VALUE.QUANT_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.QUANT_ADDR_WIDTH}] ${MODELPARAM_VALUE.QUANT_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.FC_INPUT_ADDR_WIDTH { MODELPARAM_VALUE.FC_INPUT_ADDR_WIDTH PARAM_VALUE.FC_INPUT_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FC_INPUT_ADDR_WIDTH}] ${MODELPARAM_VALUE.FC_INPUT_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.FC_CLASS_ADDR_WIDTH { MODELPARAM_VALUE.FC_CLASS_ADDR_WIDTH PARAM_VALUE.FC_CLASS_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FC_CLASS_ADDR_WIDTH}] ${MODELPARAM_VALUE.FC_CLASS_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.FC_ACC_WIDTH { MODELPARAM_VALUE.FC_ACC_WIDTH PARAM_VALUE.FC_ACC_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FC_ACC_WIDTH}] ${MODELPARAM_VALUE.FC_ACC_WIDTH}
}

