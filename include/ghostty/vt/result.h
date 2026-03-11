/**
 * @file result.h
 *
 * Result codes for libghostty-vt operations.
 *
 * 该头文件保持路径稳定（<ghostty/vt/result.h>），但实际定义已移动到共享头
 * <ghostty/result.h>，以确保 <ghostty.h> 与 <ghostty/vt.h> 可在同一 TU
 * 中同时 include（避免 GHOSTTY_SUCCESS 宏/枚举冲突）。
 */

#ifndef GHOSTTY_VT_RESULT_H
#define GHOSTTY_VT_RESULT_H

#include <ghostty/result.h>

#endif /* GHOSTTY_VT_RESULT_H */
