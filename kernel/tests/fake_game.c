// SPDX-License-Identifier: GPL-2.0
/*
 * Rago OS — faux jeu pour tester le routage de scx_rago.
 *
 * Imite la forme d'un jeu : un thread « RenderThread » qui travaille par
 * images (~4 ms de calcul puis attente jusqu'à la prochaine image à 144 Hz),
 * des threads de travail qui calculent en continu, et optionnellement un
 * processus enfant (comme un lanceur qui démarre le vrai exécutable) pour
 * vérifier l'héritage du tag au fork.
 *
 *   fake_game [-t THREADS] [-s SECONDES] [-r] [-c] [-n NOM]
 *     -t  nombre de threads de travail (défaut 4)
 *     -s  durée en secondes (défaut 20)
 *     -r  ajoute un thread nommé « RenderThread »
 *     -c  forke un processus enfant qui fait la même chose (sans -c)
 *     -n  nom des threads de travail (défaut « worker »)
 *
 * Compilation : cc -O2 -pthread -o fake_game fake_game.c
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stop;
static double deadline;
static char worker_name[16] = "worker";

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void burn(double secs)
{
	volatile unsigned long x = 0;
	double end = now() + secs;

	while (now() < end)
		for (int i = 0; i < 10000; i++)
			x += i * 2654435761u;
}

static void *worker(void *arg)
{
	char name[16];

	snprintf(name, sizeof(name), "%.10s-%ld", worker_name, (long)(size_t)arg);
	pthread_setname_np(pthread_self(), name);
	while (!stop && now() < deadline) {
		burn(0.002);
		usleep(200); /* courte attente : réveils fréquents, comme un pool de tâches */
	}
	return NULL;
}

static void *render(void *arg)
{
	const double frame = 1.0 / 144.0;
	double next = now();

	(void)arg;
	pthread_setname_np(pthread_self(), "RenderThread");
	while (!stop && now() < deadline) {
		burn(0.004);
		next += frame;
		double wait = next - now();
		if (wait > 0)
			usleep((useconds_t)(wait * 1e6));
		else
			next = now();
	}
	return NULL;
}

static void on_term(int sig)
{
	(void)sig;
	stop = 1;
}

static int run(int nthreads, int with_render)
{
	pthread_t th[256];
	int n = 0;

	for (long i = 0; i < nthreads && n < 255; i++)
		if (pthread_create(&th[n], NULL, worker, (void *)i) == 0)
			n++;
	if (with_render && pthread_create(&th[n], NULL, render, NULL) == 0)
		n++;
	for (int i = 0; i < n; i++)
		pthread_join(th[i], NULL);
	return 0;
}

int main(int argc, char **argv)
{
	int nthreads = 4, secs = 20, with_render = 0, with_child = 0, opt;
	pid_t child = -1;

	while ((opt = getopt(argc, argv, "t:s:rcn:")) != -1) {
		switch (opt) {
		case 't': nthreads = atoi(optarg); break;
		case 's': secs = atoi(optarg); break;
		case 'r': with_render = 1; break;
		case 'c': with_child = 1; break;
		case 'n': snprintf(worker_name, sizeof(worker_name), "%s", optarg); break;
		default:
			fprintf(stderr, "usage: %s [-t N] [-s S] [-r] [-c] [-n NOM]\n", argv[0]);
			return 2;
		}
	}
	signal(SIGTERM, on_term);
	signal(SIGINT, on_term);
	deadline = now() + secs;

	if (with_child) {
		child = fork();
		if (child == 0) {
			/* L'enfant : même charge, sans thread de rendu. */
			snprintf(worker_name, sizeof(worker_name), "child");
			return run(nthreads, 0);
		}
		if (child < 0)
			perror("fork");
		else
			printf("child=%d\n", child);
	}
	printf("pid=%d\n", getpid());
	fflush(stdout);

	run(nthreads, with_render);
	if (child > 0)
		waitpid(child, NULL, 0);
	return 0;
}
