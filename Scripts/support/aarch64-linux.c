/*
 * Support for the aarch64-unknown-linux-gnu Embedded concurrency runtime,
 * sealed into linux-arm64 and android-arm64-v8a slices next to
 * concurrency.c. guest.py localizes these when it seals the slice.
 *
 * The toolchain has no concurrency runtime for aarch64-none-none-elf, so
 * those slices use the Linux one (§5.4). It was built for a hosted Linux,
 * so beyond what concurrency.c covers it references:
 *
 * - outline atomics (__aarch64_cas8_acq and friends), which libgcc or
 *   compiler-rt provide on Linux. This file is compiled with
 *   -mno-outline-atomics, so the builtins below inline to exclusive
 *   load/store loops instead of calling themselves.
 * - libstdc++'s red-black tree, used by task groups and task locals
 *   (libc++, which the bare-metal runtimes are built against, keeps it in
 *   headers);
 * - glibc's spellings of errno and stderr, and the stack protector.
 *
 * Every definition is weak, like concurrency.c. Freestanding: only
 * <stddef.h> and <stdint.h>.
 */
#include <stddef.h>
#include <stdint.h>

#define WEAK __attribute__((weak))

long write(int fd, const void *buffer, size_t count);
__attribute__((noreturn)) void abort(void);

/* MARK: Outline atomics
 *
 * The libgcc/compiler-rt ABI: __aarch64_casN_ORDER(expected, desired, ptr)
 * and __aarch64_OPN_ORDER(value, ptr) return the previous value. */

#define CAS(N, T, ORDER, SUCCESS, FAILURE)                                              \
    WEAK T __aarch64_cas##N##_##ORDER(T expected, T desired, T *pointer) {              \
        __atomic_compare_exchange_n(pointer, &expected, desired, 0, SUCCESS, FAILURE);  \
        return expected;                                                                \
    }

#define RMW(NAME, N, T, ORDER, MODEL, BUILTIN, OPERAND)        \
    WEAK T __aarch64_##NAME##N##_##ORDER(T value, T *pointer) { \
        return BUILTIN(pointer, OPERAND, MODEL);                \
    }

#define ORDERS(MACRO, ...)                                                    \
    MACRO(__VA_ARGS__, relax, __ATOMIC_RELAXED, __ATOMIC_RELAXED)            \
    MACRO(__VA_ARGS__, acq, __ATOMIC_ACQUIRE, __ATOMIC_ACQUIRE)              \
    MACRO(__VA_ARGS__, rel, __ATOMIC_RELEASE, __ATOMIC_RELAXED)              \
    MACRO(__VA_ARGS__, acq_rel, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)

#define CAS_ORDER(N, T, ORDER, SUCCESS, FAILURE) CAS(N, T, ORDER, SUCCESS, FAILURE)
#define SWP_ORDER(N, T, ORDER, MODEL, UNUSED) RMW(swp, N, T, ORDER, MODEL, __atomic_exchange_n, value)
#define LDADD_ORDER(N, T, ORDER, MODEL, UNUSED) RMW(ldadd, N, T, ORDER, MODEL, __atomic_fetch_add, value)
#define LDCLR_ORDER(N, T, ORDER, MODEL, UNUSED) RMW(ldclr, N, T, ORDER, MODEL, __atomic_fetch_and, ~value)
#define LDSET_ORDER(N, T, ORDER, MODEL, UNUSED) RMW(ldset, N, T, ORDER, MODEL, __atomic_fetch_or, value)
#define LDEOR_ORDER(N, T, ORDER, MODEL, UNUSED) RMW(ldeor, N, T, ORDER, MODEL, __atomic_fetch_xor, value)

#define SIZE(N, T)                \
    ORDERS(CAS_ORDER, N, T)       \
    ORDERS(SWP_ORDER, N, T)       \
    ORDERS(LDADD_ORDER, N, T)     \
    ORDERS(LDCLR_ORDER, N, T)     \
    ORDERS(LDSET_ORDER, N, T)     \
    ORDERS(LDEOR_ORDER, N, T)

SIZE(1, uint8_t)
SIZE(2, uint16_t)
SIZE(4, uint32_t)
SIZE(8, uint64_t)
ORDERS(CAS_ORDER, 16, unsigned __int128)

/* MARK: libstdc++ red-black tree
 *
 * std::_Rb_tree_node_base: a color (red is 0) and three links. The tree's
 * header node is red; its parent is the root, its left the leftmost node
 * and its right the rightmost. Written from the textbook algorithm (CLRS,
 * insertion fix-up). */

typedef struct TreeNode {
    int color;
    struct TreeNode *parent;
    struct TreeNode *left;
    struct TreeNode *right;
} TreeNode;

enum { RED = 0, BLACK = 1 };

static void rotate_left(TreeNode *x, TreeNode **root) {
    TreeNode *y = x->right;
    x->right = y->left;
    if (y->left != NULL) {
        y->left->parent = x;
    }
    y->parent = x->parent;
    if (x == *root) {
        *root = y;
    } else if (x == x->parent->left) {
        x->parent->left = y;
    } else {
        x->parent->right = y;
    }
    y->left = x;
    x->parent = y;
}

static void rotate_right(TreeNode *x, TreeNode **root) {
    TreeNode *y = x->left;
    x->left = y->right;
    if (y->right != NULL) {
        y->right->parent = x;
    }
    y->parent = x->parent;
    if (x == *root) {
        *root = y;
    } else if (x == x->parent->right) {
        x->parent->right = y;
    } else {
        x->parent->left = y;
    }
    y->right = x;
    x->parent = y;
}

/* std::_Rb_tree_insert_and_rebalance(bool, node *x, node *parent, node &header):
 * links x as parent's left or right child, then restores the invariants. */
WEAK void rt_tree_insert_and_rebalance(int insert_left, TreeNode *x, TreeNode *p, TreeNode *header)
    __asm__("_ZSt29_Rb_tree_insert_and_rebalancebPSt18_Rb_tree_node_baseS0_RS_");
WEAK void rt_tree_insert_and_rebalance(int insert_left, TreeNode *x, TreeNode *p, TreeNode *header) {
    TreeNode **root = &header->parent;
    x->parent = p;
    x->left = NULL;
    x->right = NULL;
    x->color = RED;

    if ((insert_left & 0xff) != 0) {
        p->left = x; /* also the leftmost when p is the header */
        if (p == header) {
            header->parent = x;
            header->right = x;
        } else if (p == header->left) {
            header->left = x;
        }
    } else {
        p->right = x;
        if (p == header->right) {
            header->right = x;
        }
    }

    while (x != *root && x->parent->color == RED) {
        TreeNode *grandparent = x->parent->parent;
        if (x->parent == grandparent->left) {
            TreeNode *uncle = grandparent->right;
            if (uncle != NULL && uncle->color == RED) {
                x->parent->color = BLACK;
                uncle->color = BLACK;
                grandparent->color = RED;
                x = grandparent;
            } else {
                if (x == x->parent->right) {
                    x = x->parent;
                    rotate_left(x, root);
                }
                x->parent->color = BLACK;
                grandparent->color = RED;
                rotate_right(grandparent, root);
            }
        } else {
            TreeNode *uncle = grandparent->left;
            if (uncle != NULL && uncle->color == RED) {
                x->parent->color = BLACK;
                uncle->color = BLACK;
                grandparent->color = RED;
                x = grandparent;
            } else {
                if (x == x->parent->left) {
                    x = x->parent;
                    rotate_right(x, root);
                }
                x->parent->color = BLACK;
                grandparent->color = RED;
                rotate_left(grandparent, root);
            }
        }
    }
    (*root)->color = BLACK;
}

/* The in-order predecessor. From the header (end()), the rightmost node. */
static TreeNode *tree_decrement(TreeNode *x) {
    if (x->color == RED && x->parent->parent == x) {
        return x->right;
    }
    if (x->left != NULL) {
        TreeNode *y = x->left;
        while (y->right != NULL) {
            y = y->right;
        }
        return y;
    }
    TreeNode *y = x->parent;
    while (x == y->left) {
        x = y;
        y = y->parent;
    }
    return y;
}

/* The in-order successor. From the rightmost node, the header. */
static TreeNode *tree_increment(TreeNode *x) {
    if (x->right != NULL) {
        x = x->right;
        while (x->left != NULL) {
            x = x->left;
        }
        return x;
    }
    TreeNode *y = x->parent;
    while (x == y->right) {
        x = y;
        y = y->parent;
    }
    /* Climbing from the rightmost node of a one-node tree stops with x at
     * the header and y at the root; the successor is then x, the header
     * (end()). */
    return x->right != y ? y : x;
}

#define TREE_STEP(NAME, MANGLED, BODY)                       \
    WEAK TreeNode *NAME(TreeNode *x) __asm__(MANGLED);      \
    WEAK TreeNode *NAME(TreeNode *x) { return BODY(x); }

TREE_STEP(rt_tree_decrement, "_ZSt18_Rb_tree_decrementPSt18_Rb_tree_node_base", tree_decrement)
TREE_STEP(rt_tree_decrement_const, "_ZSt18_Rb_tree_decrementPKSt18_Rb_tree_node_base", tree_decrement)
TREE_STEP(rt_tree_increment, "_ZSt18_Rb_tree_incrementPSt18_Rb_tree_node_base", tree_increment)
TREE_STEP(rt_tree_increment_const, "_ZSt18_Rb_tree_incrementPKSt18_Rb_tree_node_base", tree_increment)

/* std::__throw_length_error(const char *): a container grew past its maximum. */
WEAK void rt_throw_length_error(const char *message) __asm__("_ZSt20__throw_length_errorPKc");
WEAK void rt_throw_length_error(const char *message) {
    size_t length = 0;
    while (message[length] != 0) {
        length++;
    }
    write(2, message, length);
    abort();
}

/* MARK: glibc */

static int error_number;

WEAK int *__errno_location(void) {
    return &error_number;
}

/* The runtime only writes to stderr; the stream is never dereferenced. */
WEAK void *stderr = NULL;

/* MARK: Stack protector
 *
 * Bionic and glibc differ in where the canary lives; the slice keeps its
 * own. */
WEAK uintptr_t __stack_chk_guard = (uintptr_t)0x595e9fbd94fda766ull;

WEAK __attribute__((noreturn)) void __stack_chk_fail(void) {
    abort();
}
