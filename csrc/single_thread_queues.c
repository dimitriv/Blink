#include <stdio.h>
#include <stdlib.h>

#include <memory.h>
#include "single_thread_queues.h"
#include "bit.h"


void _stq_init(queue* q, size_t capacity, size_t elem_size) {
	q->capacity = capacity;
	q->elem_size = elem_size;
	q->size = 0;
	q->buffer_start = (char *) malloc(capacity * elem_size);
	if (q->buffer_start == NULL) {
		exit(EXIT_FAILURE);
	}
	// buffer_end points at the first memory location beyond the buffer
	q->buffer_end = q->buffer_start + capacity * elem_size;
	q->next_write = q->buffer_start;
	q->next_read  = q->buffer_start;
}

/* Queue reader API 
 ***************************************************************************/

// Peek n slots into the queue (if aligned, throw error otherwise, or perhaps emit slow path -- todo)
FORCE_INLINE char* stq_acquire(queue *q)
{

#ifdef QUEUE_CHECKS_ENABLED
	if (q->next_read + q->acquired*q->elem_size > q->buffer_end)
	{
		printf("Unaligned queue read!");
		exit(EXIT_FAILURE);
	}
#endif
	return q->next_read;
}

// Release the acquired slots 
FORCE_INLINE void stq_release(queue *q)
{
	char *ptr = q->next_read;
	ptr = ptr + q->elem_size;
	if (ptr == q->buffer_end) ptr = q->buffer_start;
	q->next_read = ptr;
}

/* Queue write API
***************************************************************************/

FORCE_INLINE char* stq_reserve(queue *q)
{
	// reserve n slots
//	q->reserved += slots;

#ifdef QUEUE_CHECKS_ENABLED
	if (q->next_write + q->reserved*q->elem_size > q->buffer_end)
	{
		printf("Unaligned queue write!");
		exit(EXIT_FAILURE);
	}
#endif
	return q->next_write;
}

FORCE_INLINE void stq_push(queue *q)
{
	char*ptr = q->next_write;
	ptr = ptr + q->elem_size;
	if (ptr == q->buffer_end) ptr = q->buffer_start;
//	q->reserved = 0;
	q->next_write = ptr;
}


FORCE_INLINE void stq_clear(queue *q)
{
//	q->acquired = 0;
//	q->reserved = 0;
	q->next_read = q->buffer_start;
	q->next_write = q->buffer_start;
	q->size = 0;
}

FORCE_INLINE void stq_rollback(queue* q, size_t n) {
	char* ptr = q->next_read - (q->elem_size*n);
#ifdef QUEUE_CHECKS_ENABLED
	// ASSERT(q->acquired == 0 && q->reserved == 0);
	if (ptr < q->buffer_start)
	{
		printf("Unaligned queue rollback!");
		exit(EXIT_FAILURE);
	}
#endif
	q->next_read = ptr;

}

/* Top-level API 
 *********************************************************************/

static queue *queues;

queue * stq_init(int no, size_t *sizes, int *queue_capacities) {
	queues = (queue *) malloc(no * sizeof(queue));

	if (queues == NULL) exit(EXIT_FAILURE);

	for (size_t i = 0; i < no; i++)
	{
		_stq_init(&queues[i], queue_capacities[i], sizes[i]);
	}
	return queues;
}
