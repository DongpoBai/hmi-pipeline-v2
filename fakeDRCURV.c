/* GSL substitute for DRCURV routine found in IMSL Fortran Library
 * Written by: Dongpo Bai (with assistance)
 * Date: 2026-03-22
 *
 * DRCURV performs polynomial regression (least squares fit) of degree NDEG.
 * This implementation uses GSL's multifit linear algebra routines.
 *
 * IMSL interface:
 *   CALL DRCURV(NOBS, XDATA, YDATA, NDEG, B, SSPOLY, STAT)
 *
 * Parameters:
 *   NOBS   - (int)    Number of observations
 *   XDATA  - (double) Array of x values, length NOBS
 *   YDATA  - (double) Array of y values, length NOBS
 *   NDEG   - (int)    Degree of polynomial to fit (0=constant, 1=linear, etc.)
 *   B      - (double) Output: polynomial coefficients B(0)..B(NDEG)
 *                      y = B(0) + B(1)*x + B(2)*x^2 + ... + B(NDEG)*x^NDEG
 *   SSPOLY - (double) Output: sequential sums of squares, length NDEG+1
 *   STAT   - (double) Output: statistics array, length 12
 *            STAT(1)  = Mean of X
 *            STAT(2)  = Mean of Y
 *            STAT(3)  = Sample Variance of X
 *            STAT(4)  = Sample Variance of Y
 *            STAT(5)  = R-squared (coefficient of determination)
 *            STAT(6)  = Degrees of freedom for regression (= NDEG)
 *            STAT(7)  = Sum of squares for regression (SSR)
 *            STAT(8)  = Degrees of freedom for error (= NOBS - NDEG - 1)
 *            STAT(9)  = Sum of squares for error (SSE)
 *            STAT(10) = (unused, set to 0)
 *            STAT(11) = (unused, set to 0)
 *            STAT(12) = Number of NaN values found
 *
 * Based on the fakeDRLINE.c pattern by Cesar Sul (2016).
 */

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <gsl/gsl_math.h>
#include <gsl/gsl_statistics.h>
#include <gsl/gsl_multifit.h>
#include <gsl/gsl_fit.h>

static int count_nan(double *x, double *y, int n) {
    int count = 0;
    int i;
    for (i = 0; i < n; i++) {
        if (isnan(x[i]) || isnan(y[i])) {
            count++;
        }
    }
    if (count > 0) {
        printf("\n\nWarning, NaN Encountered in DRCURV.\n\n");
    }
    return count;
}

void fakeDRCURV(int n, double *x, double *y, int ndeg,
                double *B, double *SSPOLY, double *STAT) {
    int i, j;

    /* Compute basic statistics */
    double mean_x = gsl_stats_mean(x, 1, n);
    double mean_y = gsl_stats_mean(y, 1, n);
    double var_x  = gsl_stats_variance_m(x, 1, n, mean_x);
    double var_y  = gsl_stats_variance_m(y, 1, n, mean_y);

    /* Total sum of squares: SST = var_y * (n-1) */
    double SST = var_y * (n - 1);

    /* Initialize outputs */
    for (j = 0; j <= ndeg; j++) {
        B[j] = 0.0;
        SSPOLY[j] = 0.0;
    }
    for (i = 0; i < 12; i++) {
        STAT[i] = 0.0;
    }

    if (ndeg == 0) {
        /* Degree 0: constant fit = mean(y) */
        B[0] = mean_y;
        SSPOLY[0] = 0.0; /* No reduction from the constant beyond the mean */

        double SSE = SST; /* All variation is "error" for constant model */
        double SSR = 0.0;

        STAT[0] = mean_x;
        STAT[1] = mean_y;
        STAT[2] = var_x;
        STAT[3] = var_y;
        STAT[4] = 0.0;                /* R^2 = 0 for constant model */
        STAT[5] = 0.0;                /* DOF regression = 0 */
        STAT[6] = 0.0;                /* SSR = 0 */
        STAT[7] = (double)(n - 1);    /* DOF error = n - 1 */
        STAT[8] = SSE;                /* SSE = SST */
        STAT[9] = 0.0;
        STAT[10] = 0.0;
        STAT[11] = (double)count_nan(x, y, n);

    } else if (ndeg == 1) {
        /* Degree 1: use GSL linear fit for best accuracy */
        double c0, c1, cov00, cov01, cov11, chisq;
        gsl_fit_linear(x, 1, y, 1, n, &c0, &c1, &cov00, &cov01, &cov11, &chisq);

        B[0] = c0;
        B[1] = c1;

        double SSE = chisq;
        double SSR = SST - SSE;
        double R2 = (SST > 0.0) ? SSR / SST : 0.0;

        /* Sequential SS: SSPOLY[0] = SS due to constant, SSPOLY[1] = SS due to linear term */
        SSPOLY[0] = (double)n * mean_y * mean_y;
        SSPOLY[1] = SSR;

        STAT[0] = mean_x;
        STAT[1] = mean_y;
        STAT[2] = var_x;
        STAT[3] = var_y;
        STAT[4] = R2;
        STAT[5] = 1.0;                /* DOF regression = 1 */
        STAT[6] = SSR;
        STAT[7] = (double)(n - 2);    /* DOF error = n - 2 */
        STAT[8] = SSE;
        STAT[9] = 0.0;
        STAT[10] = 0.0;
        STAT[11] = (double)count_nan(x, y, n);

    } else {
        /* General polynomial fit of degree ndeg using GSL multifit */
        gsl_matrix *X = gsl_matrix_alloc(n, ndeg + 1);
        gsl_vector *Y = gsl_vector_alloc(n);
        gsl_vector *c = gsl_vector_alloc(ndeg + 1);
        gsl_matrix *cov = gsl_matrix_alloc(ndeg + 1, ndeg + 1);
        double chisq;

        /* Build Vandermonde matrix */
        for (i = 0; i < n; i++) {
            gsl_vector_set(Y, i, y[i]);
            double xi = 1.0;
            for (j = 0; j <= ndeg; j++) {
                gsl_matrix_set(X, i, j, xi);
                xi *= x[i];
            }
        }

        /* Perform the fit */
        gsl_multifit_linear_workspace *work = gsl_multifit_linear_alloc(n, ndeg + 1);
        gsl_multifit_linear(X, Y, c, cov, &chisq, work);
        gsl_multifit_linear_free(work);

        /* Extract coefficients */
        for (j = 0; j <= ndeg; j++) {
            B[j] = gsl_vector_get(c, j);
        }

        double SSE = chisq;
        double SSR = SST - SSE;
        double R2 = (SST > 0.0) ? SSR / SST : 0.0;

        /* Sequential sums of squares (approximate):
         * Fit polynomials of degree 0, 1, ..., ndeg and compute
         * the reduction in SSE at each step */
        SSPOLY[0] = (double)n * mean_y * mean_y;
        double prev_SSE = SST;

        for (j = 1; j <= ndeg; j++) {
            /* Fit polynomial of degree j */
            gsl_matrix *Xj = gsl_matrix_alloc(n, j + 1);
            gsl_vector *cj = gsl_vector_alloc(j + 1);
            gsl_matrix *covj = gsl_matrix_alloc(j + 1, j + 1);
            double chisqj;
            int ii, jj;

            for (ii = 0; ii < n; ii++) {
                double xi = 1.0;
                for (jj = 0; jj <= j; jj++) {
                    gsl_matrix_set(Xj, ii, jj, xi);
                    xi *= x[ii];
                }
            }

            gsl_multifit_linear_workspace *workj = gsl_multifit_linear_alloc(n, j + 1);
            gsl_multifit_linear(Xj, Y, cj, covj, &chisqj, workj);
            gsl_multifit_linear_free(workj);

            SSPOLY[j] = prev_SSE - chisqj;
            prev_SSE = chisqj;

            gsl_matrix_free(Xj);
            gsl_vector_free(cj);
            gsl_matrix_free(covj);
        }

        STAT[0] = mean_x;
        STAT[1] = mean_y;
        STAT[2] = var_x;
        STAT[3] = var_y;
        STAT[4] = R2;
        STAT[5] = (double)ndeg;              /* DOF regression */
        STAT[6] = SSR;
        STAT[7] = (double)(n - ndeg - 1);    /* DOF error */
        STAT[8] = SSE;
        STAT[9] = 0.0;
        STAT[10] = 0.0;
        STAT[11] = (double)count_nan(x, y, n);

        gsl_matrix_free(X);
        gsl_vector_free(Y);
        gsl_vector_free(c);
        gsl_matrix_free(cov);
    }
}

/*
 * Fortran-callable interface (name-mangled with trailing underscore)
 * Fortran passes all arguments by reference.
 */
extern void drcurv_(int *nobs, double *xdata, double *ydata, int *ndeg,
                    double *B, double *SSPOLY, double *STAT);

void drcurv_(int *nobs, double *xdata, double *ydata, int *ndeg,
             double *B, double *SSPOLY, double *STAT) {
    fakeDRCURV(*nobs, xdata, ydata, *ndeg, B, SSPOLY, STAT);
}
