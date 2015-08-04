#include <stdlib.h>
#include <memory.h>
#include "single_thread_queues.h"
#include "bit.h"

queue *queues;

void aq_init(int no, size_t *sizes, int *queue_sizes) {
	queues = (queue *)(malloc(no * sizeof(queue)));
	if (queues == NULL) {
		exit(EXIT_FAILURE);
	}

	for (size_t i = 0; i < no; i++)
	{
		queue_init(&queues[i], queue_sizes[i], sizes[i]);
	}
}


/* low-level Interface **********************************************/

FORCE_INLINE void advance_ptr(void** ptr_ptr, size_t n, queue* q) {
	char* ptr = (char *) *ptr_ptr;
	ptr += n * q->elem_size;
	if (ptr >= q->buffer_end) {
		ptr -= q->capacity * q->elem_size;
	}
}

FORCE_INLINE bool is_empty(queue* q) {
	return q->size == 0;
}

FORCE_INLINE bool is_full(queue* q) {
	return q->size == q->capacity;
}

FORCE_INLINE size_t free_slots(queue* q) {
	return q->capacity - q->size;
}


void queue_init(queue* q, size_t capacity, size_t elem_size) {
	q->capacity = capacity;
	q->elem_size = elem_size;
	q->size = 0;
	q->buffer_start = malloc(capacity * elem_size);
	if (q->buffer_start == NULL) {
		exit(EXIT_FAILURE);
	}
	// buffer_end points at the first memory location beyond the buffer
	q->buffer_end = (char*) q->buffer_start + capacity * elem_size;
	q->next_write = q->buffer_start;
	q->next_read = q->buffer_start;
}




/* api **********************************************************/

void clear(queue* q) {
	q->size = 0;
	q->next_write = q->buffer_start;
	q->next_read = q->buffer_start;
}

void rollback(size_t n, queue* q) {
#ifdef QUEUE_CHECKS_ENABLED
	if (free_slots(q) < n) {
		exit(EXIT_FAILURE);
	}
#endif

	advance_ptr(&q->next_read, q->capacity - n, q);
}


void push(void* elem, queue* q) {
#ifdef QUEUE_CHECKS_ENABLED
	if (is_full(q)) {
		exit(EXIT_FAILURE);
	}
#endif

	memcpy(q->next_write, elem, q->elem_size);
	advance_ptr(&q->next_write, 1, q);
	q->size++;
}

void pushN(void* elems, size_t n, queue* q) {
#ifdef QUEUE_CHECKS_ENABLED
	if (free_slots(q) < n) {
		exit(EXIT_FAILURE);
	}
#endif

	size_t can_write = ((char *) q->buffer_end - q->next_write) / q->elem_size;
	if (can_write >= n) {
		memcpy(q->next_write, elems, n * q->elem_size);
	}
	else {
		memcpy(q->next_write, elems, can_write * q->elem_size);
		advance_ptr(&elems, can_write, q);
		memcpy(q->buffer_start, elems, (n - can_write) * q->elem_size);
	}

	advance_ptr(&q->next_write, n, q);
	q->size += n;
}

void pushNBits(void* elems, size_t n, queue* q) {
	unsigned char unpacked_bit[1];
	for (int i = 0; i < n; i++)
	{
		bitRead((BitArrPtr) elems, i, unpacked_bit);
		push(unpacked_bit, q);
	}
}


void pop(void* elem, queue* q) {
#ifdef QUEUE_CHECKS_ENABLED
	if (is_empty(q)) {
		exit(EXIT_FAILURE);
	}
#endif

	memcpy(elem, q->next_read, q->elem_size);
	q->size--;
	advance_ptr(&q->next_read, 1, q);
}

void popN(void* elems, size_t n, queue* q) {
#ifdef QUEUE_CHECKS_ENABLED
	if (q->size < n) {
		exit(EXIT_FAILURE);
	}
#endif

	size_t can_read = ((char *)q->buffer_end - q->next_read) / q->elem_size;
	if (can_read >= n) {
		memcpy(elems, q->next_read, n * q->elem_size);
	}
	else {
		memcpy(elems, q->next_read, can_read * q->elem_size);
		advance_ptr(&elems, can_read, q);
		memcpy(elems, q->buffer_start, (n - can_read) * q->elem_size);
	}

	advance_ptr(&q->next_read, n, q);
	q->size -= n;
}

void popNBits(void* elems, size_t n, queue* q) {
	
	Bit unpacked_bit;

	for (int i = 0; i<n; i++)
	{
		pop(&unpacked_bit, q);
		bitWrite((BitArrPtr) elems, i, unpacked_bit);
	}
}



/**************************/

FORCE_INLINE void aq_put(int nc, char *input) {
	push(input, &queues[nc]);
}

FORCE_INLINE void aq_putMany(int nc, int n, char *input) {
	pushN(input, n, &queues[nc]);
}

FORCE_INLINE void aq_putManyBits(int nc, int n, char *input) {
	pushNBits(input, n, &queues[nc]);
}

FORCE_INLINE void aq_get(int nc, char *output) {
	pop(output, &queues[nc]);
}

FORCE_INLINE void aq_getMany(int nc, int n, char *output) {
	popN(output, n, &queues[nc]);
}

FORCE_INLINE void aq_getManyBits(int nc, int n, char *output) {
	popNBits(output, n, &queues[nc]);
}
