#!/bin/bash

odin build demo -define:Reify_Enable_Validation=true

VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation ./demo.bin
