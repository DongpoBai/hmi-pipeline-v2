/* GSL substitute for DRLINE routine found in IMSL Fortran Library
 * Written by: Cesar Sul
 * Last Edited 3/29/2016
 *
 * This is based off of the fakeRLINE routine. There have been some
 * changes, such as how the standard errors are calculated and a
 * few aesthetic edits.
 *
 * Please include a citation similar to the following in any publication
 * resulting from the use of this code:
 *
 * This research was supported by Advanced CyberInfrastructure Research
 * and Education Facilitators NSF award ID 1341935
*/
// Headers
#include<stdio.h>
#include<gsl/gsl_math.h>
#include<gsl/gsl_fit.h>
#include<gsl/gsl_statistics.h>



int NaN_Counter(double* xVals, double* yVals, int arrayLen){
	int NaN_Count = 0;
	int i;
	for(i = 0; i < arrayLen; i++){
		//if ( xVals[i] != xVals[i] || yVals[i] != yVals[i] ){
		if ( isnan(xVals[i]) || isnan( yVals[i]) ){
			NaN_Count++;
		}
	}
   if(NaN_Count >0){
   printf("\n\nWarning, NaN Encountered.\n\n");
   }
	return NaN_Count;
}

int validate(double this_Val, double valid_Val, double tol){
/* Compare two values to make sure they agree within allowed tolerance */
	double dif = (this_Val - valid_Val);
   double relative_dif = dif/valid_Val;
   if(dif==0){
   return 1;
   }
   if(relative_dif < 0){
   relative_dif *=-1;
   }
	if( relative_dif <=  tol ){
		//printf("All is well.\n");
		return 1;
	}else{
		//printf("Test failed!\n");
	 	//printf("Recieved : %.2f Expected : %.2f\n\n" , this_Val, valid_Val);
	 	//printf("Difference was %f\n", dif);
		return 0;
	}
}

double * calc_SE(double ** cov_diags, double chisqr, int dof, int len){
/* The calculations for the standard errors come from the diagonal elements from the
 * covariance matrix, just take the square root. For an unweighted fit there is
 * an additional factor of sqrt( chisqr / degrees of freedom)
 **/
   double *output = malloc(sizeof(double)*len);
   int i;
   for(i=0; i < len; i++){
   output[i] = sqrt(*cov_diags[i]);
   }
   return output;
 }
 // Create linear model
 void fakeDRLINE( int n, double *xVals, double *yVals, double **B0, double **B1, double *STAT){
 // We'll use the same syntax as RLINE and calculate some of the things that IMSL did
    	
 	// These numbers aren't used outside of this function.
	// GSL requires doubles while IMSL RLINE uses double (Single precision, AKA real)
	// This is the easiest work around.
	double cov00, cov01, cov11, chisqr; 
   int k = 2; // Number of fit parameters
   
	gsl_fit_linear (xVals, 1, yVals, 1, n,
                    *B0, *B1, &cov00, &cov01, &cov11, &chisqr);
// GSL easily computes B0 and B1.

/*	The covariance matrix from GSL is not computing the variances and covariances
	that we all know and love. Instead it's computing a matrix that can be used
   to find fit uncertainties.

	printf("cov00 = %f\n", cov00);
	printf("cov01 = %f\n", cov01);
	printf("cov11 = %f\n", cov11);
	printf("chisqr = %f\n", chisqr); //chisqr is equivalent to the Sum of Squares for error
*/

// We'll have to make our own STAT vector using as much of the GSL library as possible
    STAT[0]  = gsl_stats_mean(xVals, 1, n);    // Mean of x
    STAT[1]  = gsl_stats_mean(yVals, 1, n);    // Mean of y
    STAT[2]  = gsl_stats_variance_m(xVals, 1, n, STAT[0]);    // Variance of x
    STAT[3]  = gsl_stats_variance_m(yVals, 1, n, STAT[1]);    // Variance of y
    STAT[4]  = gsl_stats_covariance_m(xVals, 1, yVals, 1, n, STAT[0], STAT[1])/sqrt(STAT[2] *  STAT[3]);    // Correlation
    double *cov_diags[2] = {&cov00, &cov11}; 
    double * standard_errors = calc_SE(cov_diags, chisqr, n-k, k);
    STAT[5] = standard_errors[0];
    STAT[6] = standard_errors[1];
    STAT[7]  = 1;     // Degrees of freedom for regression always return 1
/*
 * Sum of squares regression
 * SSR = SST - SSE
 * SST = Variance[y] * (n -1)
 * SSR = Variance[y] * (n-1) - chisqr
 */
    STAT[8]  = STAT[3] * (n-1) - chisqr;// Sum of squares for regression
    STAT[9]  = n-k;    // Degrees of freedom for error there are two fit parameters
    STAT[10] = chisqr;		// Sum of Squares for error
    STAT[11] = NaN_Counter( xVals, yVals, n);    // Number of (x,y) points containing NaN
    

}
void compare_test_and_valid_values(int len, double* values_to_test, double *valid_values, 
                                   char** testNames, double *tolerance, int * verbose){

	printf ("\n");
	int failure_count = 0;
   int i;
   for (i = 0 ; i < len; i++) {

	   if(*verbose){
	   	printf("Testing %d : %s\n", i, testNames[i]);
		}
	
    	if ( !validate( values_to_test[i], valid_values[i],*tolerance) ){
			failure_count++;
			printf("***************Test %d, %s, failed!***************\n", i, testNames[i]);
	 		printf("Recieved : %.5f Expected : %.5f\n" , values_to_test[i], valid_values[i]);
			printf("The relative difference was %f%\n\n",100* (values_to_test[i] - valid_values[i])/valid_values[i]);
		}else if (*verbose){
	 		printf("Recieved : %f Expected : %f\n" , values_to_test[i], valid_values[i]);
			printf("The relative difference was %f%\n\n",100* (values_to_test[i] - valid_values[i])/valid_values[i]);
		}
    }
	printf("%d/%d Tests Passed.\n", len - failure_count, len);
}
void test(int n, double *x, double *y, double *B0_Valid, double *B1_Valid, double *STAT_Valid, double *tolerance, int *verbose ){
//Verify that our values made it through

//printf("n = %u\n", n);
//printf("tolerance = %f\n", *tolerance);

/*
 * A test function for fakeRLINE to compare output with IMSL RLINE. The output from IMSL RLINE
 * can be fed here and the calculated values will be compared. Provide pointers to a valid B0, B1, and STAT
 * Useful for automated testing.
 * 
 * Test will check to see if Valid values and fakeRLINE values agree within tolerance.
 * If verbose = 1, test() will output a summary table, otherwise, only failed tests will
 * be included. An empty table is good.
 */ 
	/* double *STAT[] = { meanX_Valid, meanY_Valid, sVarX_Valid, sVarY_Valid, corr_valid,\
     *					   std_Err_B0_Valid, std_Err_B1_Valid, DF_Reg_Valid, SS_Reg_Valid,\
	 *					   DF_Err_Valid, SS_Err_Valid, pts_NaN_Valid };
	 */
	// Create values to be validated
   double cov00, cov01, cov11, chisq, corr;
	double B0 = -1.23;    //Just to Verify that this value gets updated in fakeRLINE
	double *B0_Ptr = &B0; //Pass a pointer to a pointer to get this calculations
	double B1 = -4.56;
	double *B1_Ptr = &B1;
   double STAT[12];
   	
    fakeDRLINE(n, x, y, &B0_Ptr, &B1_Ptr, STAT);
   // Begin Validation
   
   // Error messages
	char *testNames[14] = {   "B0","B1","Mean of x", "Mean of y", "Variance of x", "Variance of y", 
						"Correlation", "Sigma_B0","Sigma_B1", "DOF Regression", 
						"Sum of Squares: Regression" , "DOF Error",
						"Sum of Squares: Error", "NaN"};	
// Generate test vector
	//double values_to_test[14] = {};
	double values_to_test[14];
	values_to_test[0]  = B0;
	values_to_test[1]  = B1;



	int i;
	for(i= 0; i < 12; i++){
		values_to_test[i+2] = STAT[i];
	}
// Generate validation vector
	double valid_values[14];
	valid_values[0]  = *B0_Valid;
	valid_values[1]  = *B1_Valid;

	for(i= 0; i < 12; i++){
		valid_values[i+2]  = STAT_Valid[i];
	}
// Start comparisions
compare_test_and_valid_values(14, values_to_test, valid_values, testNames, tolerance, verbose);
}

/*********************** This is our interace to the outside world *********************************/



extern void drline_(int *nobs,double *xdata, double *ydata, double * B0, double* B1, double *STAT);
extern void drlineverify_(int *nobs,double *xdata, double *ydata, double * B0_Valid, double* B1_Valid, 
                         double *STAT_Valid, double * tolerance, int * verbose);

extern void drlinetest_();
   
  void drline_(int *nobs,double *xdata, double *ydata, double* B0, double* B1, double *STAT){
  fakeDRLINE(*nobs, xdata, ydata, &B0, &B1, STAT);

}

void drlineverify_(int *nobs,double *xdata, double *ydata, double * B0_Valid, double* B1_Valid, 
                  double *STAT_Valid, double *tolerance, int *verbose){
    test(*nobs, xdata, ydata, B0_Valid, B1_Valid, STAT_Valid, tolerance, verbose);
}
void drlinetest_(){

// Valid data
	double B0_Valid         =  13.62;
	double B1_Valid         = -0.07983;
	double corr_Valid       = -0.8452;
	double meanX_Valid      =  52.6;
	double meanY_Valid      =  9.424;
	double sVarX_Valid      =  298.1;
	double sVarY_Valid      =  2.659;
	double DF_Reg_Valid     =  1.0;
	double SS_Reg_Valid     =  45.59;
	double DF_Err_Valid     =  23.0;
	double SS_Err_Valid     =  18.22;
	int    pts_NaN_Valid    =  0;
	double std_Err_B0_Valid =  0.5815;
	double std_Err_B1_Valid =  0.01052;

// Input Data
	int    n     = 25;

	double x[25] = {35.3, 29.7, 30.8, 58.8, 61.4, 71.3, 74.4, 76.7, 70.7,
		       57.5, 46.4, 28.9, 28.1, 39.1, 46.8, 48.5, 59.3, 70.0, 70.0,
		       74.5, 72.1, 58.1, 44.6, 33.4, 28.6};

	double y[25] = {10.98, 11.13, 12.51, 8.4, 9.27, 8.73, 6.36, 8.5,
		        7.82, 9.14, 8.24, 12.19, 11.88, 9.57, 10.94, 9.58, 10.09,
			8.11, 6.83, 8.88, 7.68, 8.47, 8.86, 10.36, 11.08};

	double STAT[12] = { meanX_Valid, meanY_Valid, sVarX_Valid, sVarY_Valid, corr_Valid,\
					   std_Err_B0_Valid, std_Err_B1_Valid, DF_Reg_Valid, SS_Reg_Valid,\
					   DF_Err_Valid, SS_Err_Valid, pts_NaN_Valid };
// The goal here is to get IMSL RLINE to create validated data, and then call *****test() from RLINE.c
// So we can get automatic tests going
   double tol     = pow(10,-3);
   int verbose    = 0;
	//printf("Starting test\n");
    test(n, x, y, &B0_Valid, &B1_Valid, STAT, &tol, &verbose);
	printf("Test ended\n");

}
