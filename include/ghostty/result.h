/**
 * @file result.h
 *
 * Shared result codes for Ghostty C APIs.
 *
 * 注意：该结果码目前主要用于“成功/失败”判断（GHOSTTY_SUCCESS）。
 * 其它错误码主要由 libghostty-vt 使用；libghostty 的大多数 API 仍以 0/非 0
 * 的约定返回整型错误码。
 */

#ifndef GHOSTTY_RESULT_H
#define GHOSTTY_RESULT_H

/**
 * Result codes for Ghostty C APIs.
 */
typedef enum {
    /** Operation completed successfully */
    GHOSTTY_SUCCESS = 0,
    /** Operation failed due to failed allocation */
    GHOSTTY_OUT_OF_MEMORY = -1,
    /** Operation failed due to invalid value */
    GHOSTTY_INVALID_VALUE = -2,
} GhosttyResult;

#endif /* GHOSTTY_RESULT_H */

