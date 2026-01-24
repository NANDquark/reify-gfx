#!/bin/bash

odin build demo

VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation ./demo.bin
