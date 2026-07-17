/* GSL substitutes for IMSL statistical distribution functions
 * Written by: Dongpo Bai (with assistance)
 * Date: 2026-03-22
 *
 * Replaces:
 *   DTDF(t, df)   - t-distribution CDF: P(T <= t)
 *   DTIN(p, df)   - t-distribution inverse CDF (quantile): t such that P(T <= t) = p
 *   DNORDF(z)     - standard normal CDF: P(Z <= z)
 *   DNORIN(p)     - standard normal inverse CDF (quantile): z such that P(Z <= z) = p
 *
 * Uses GSL CDF functions which are exact replacements.
 */

#include <gsl/gsl_cdf.h>

/*
 * DTDF: t-distribution CDF
 * Returns P(T <= t) for Student's t-distribution with df degrees of freedom
 */
double dtdf_(double *t, double *df) {
    return gsl_cdf_tdist_P(*t, *df);
}

/*
 * DTIN: t-distribution inverse CDF (quantile function)
 * Returns t such that P(T <= t) = p
 */
double dtin_(double *p, double *df) {
    return gsl_cdf_tdist_Pinv(*p, *df);
}

/*
 * DNORDF: standard normal CDF
 * Returns P(Z <= z) for standard normal distribution
 */
double dnordf_(double *z) {
    return gsl_cdf_ugaussian_P(*z);
}

/*
 * DNORIN: standard normal inverse CDF (quantile function)
 * Returns z such that P(Z <= z) = p
 */
double dnorin_(double *p) {
    return gsl_cdf_ugaussian_Pinv(*p);
}
