cmake_minimum_required(VERSION 3.10.2)

add_library(my_synth SHARED
            my_synth.c
            # 他にソースファイルがあればここに並べる
)
