#ifndef SKYNET_ATOMIC_H
#define SKYNET_ATOMIC_H

#define ATOM_CAS(ptr, oval, nval) __sync_bool_compare_and_swap(ptr, oval, nval)
#define ATOM_CAS_POINTER(ptr, oval, nval) __sync_bool_compare_and_swap(ptr, oval, nval)
#define ATOM_INC(ptr) __sync_add_and_fetch(ptr, 1)
#define ATOM_FINC(ptr) __sync_fetch_and_add(ptr, 1)
#define ATOM_DEC(ptr) __sync_sub_and_fetch(ptr, 1)
#define ATOM_FDEC(ptr) __sync_fetch_and_sub(ptr, 1)
#define ATOM_ADD(ptr,n) __sync_add_and_fetch(ptr, n)
#define ATOM_SUB(ptr,n) __sync_sub_and_fetch(ptr, n)
#define ATOM_AND(ptr,n) __sync_and_and_fetch(ptr, n)

/* 
** acquire barrier:它保证本指令执行完之后才执行它之后的指令。但是有可能它之前的指令
** 还没有被执行
**
** release barrier:它保证本指令执行的时候它之前的所有指令都已经执行完成。但是有可能
** 它之后的指令先于它执行
**
** full barrier:Acquire + Release
*/

/*
比较ptr所指向的内容和oldvalue，如果相等，则将newval写入ptr所指向的位置，并返回true
	bool __sync_bool_compare_and_swap (type *ptr, type oldval type newval, ...)

比较ptr所指向的内容和oldvalue，如果相等，则将newval写入ptr所指向的位置，无论是否相等均返回修改之前的ptr指向的值
	type __sync_val_compare_and_swap (type *ptr, type oldval type newval, ...)
*/


/*
	执行操作，并返回修改过后的值, full barrier

	type __sync_add_and_fetch (type *ptr, type value, ...)
	type __sync_sub_and_fetch (type *ptr, type value, ...)
	type __sync_or_and_fetch (type *ptr, type value, ...)
	type __sync_and_and_fetch (type *ptr, type value, ...)
	type __sync_xor_and_fetch (type *ptr, type value, ...)
	type __sync_nand_and_fetch (type *ptr, type value, ...)
*/

/*
	执行操作，并返回修改之前的值
	type __sync_fetch_and_add (type *ptr, type value, ...)
	type __sync_fetch_and_sub (type *ptr, type value, ...)
	type __sync_fetch_and_or (type *ptr, type value, ...)
	type __sync_fetch_and_and (type *ptr, type value, ...)
	type __sync_fetch_and_xor (type *ptr, type value, ...)
	type __sync_fetch_and_nand (type *ptr, type value, ...)
*/

/*
This builtin issues a full memory barrier.
	__sync_synchronize (...)
*/

/*
** This builtin, as described by Intel, is not a traditional test-and-set operation,
** but rather an atomic exchange operation. It writes value into *ptr, and returns 
** the previous contents of *ptr.
**
** Many targets have only minimal support for such locks, and do not support a full
** exchange operation. In this case, a target may support reduced functionality here
** by which the only valid value to store is the immediate constant 1. The exact value
** actually stored in *ptr is implementation defined.
**
** This builtin is not a full barrier, but rather an acquire barrier. This means that
** references after the builtin cannot move to (or be speculated to) before the builtin,
** but previous memory stores may not be globally visible yet, and previous memory loads
** may not yet be satisfied. 
**
**			type __sync_lock_test_and_set (type *ptr, type value, ...)
*/


/*
释放__sync_lock_test_and_set锁.通常就是把0写入ptr
This builtin is not a full barrier, but rather a release barrier. This means 
that all previous memory stores are globally visible, and all previous memory
loads have been satisfied, but following memory reads are not prevented from 
being speculated to before the barrier.

	void __sync_lock_release (type *ptr, ...)
*/
#endif

