#' Distance between vectors
#'
#' @param z Matrix or vector of observations
#'
#' @return Distance matrix
#' @importFrom stats dist
#' @export
#' @examples
#' set.seed(100)
#' z <- rbind(matrix(rnorm(100), ncol=4),
#' matrix(rnorm(100, 2), ncol=4))
#' get_dist_mat(z)
get_dist_mat <- function(z){
  z_dist <- as.matrix(dist(z))
  return(z_dist)
}


#' Local regression on one-on-one paired by p value
#'
#' @param D Original distance matrix
#' @param z Lower dimension representation
#' @param y Treatment vector
#'
#' @return matrix of pseudo-F values;
#' 1st col of original data, 2nd col of reduced dim
#' @export
pair_by_rank <- function(D, z, y){
  f0_sorted <- get_p(d=D, trt=y)$ratio_all
  fz_sorted <- get_p(mat=z, trt=y)$ratio_all
  mat_pair <- cbind(f0_sorted, fz_sorted)
  return(mat_pair)
}


#' MDS objective
#'
#' @param D Original distance matrix
#' @param z Lower dimension representation
#'
#' @return Scalar of objective function value of MDS
#' @export
mds_obj <- function(D, z){
  z_distmat <- get_dist_mat(z)
  return(sum((D - z_distmat)^2)/2)
}


#' Confirmatory objective term with labels
#'
#' @param y Treatment vector
#' @param z Lower dimension representation
#' @param D Original distance matrix
#'
#' @return list of objective values and sign (for computation later)
#' @export
conf_obj <- function(y, z, D){
  N <- length(y)
  a <- length(unique(y))
  z_distmat <- get_dist_mat(z)
  y_indmat <- get_ind_mat(y)
  f_ratio <- pseudo_F(d = D, trt = y)
  list_pair <- pair_by_rank(D=D, z=z, y=y) # _0, _z
  ind_f_ratio <- which.min(abs(f_ratio - list_pair[,1]))[1]
  f_ratio_pred <- list_pair[,2][ind_f_ratio]
  val <- (1 - a * y_indmat * (1 + f_ratio_pred*(a-1)/(N-a))) * z_distmat^2
  res <- abs(sum(val))
  return(list(val = res, sign = sign(sum(val))))
}


#' MM algorithm for FMDS
#'
#' @param nit Number of iterations; 100 by default
#' @param lambda Hyperparameter; 0.2 by default
#' @param z0 Initialization of configuration; Can use MDS output or random init.
#' @param D Original distance matrix
#' @param y Treatment vector
#' @param z Object matrix; used to build distance matrix d; d is prioritized
#'
#' @return list of z: obtained configuration,
#' F_z: obtained pseuo-F value, F_0: original pseudo-F value
#' @importFrom stats dist
#' @export
#' @examples
#' set.seed(100)
#' z <- rbind(matrix(rnorm(100), ncol=4),
#' matrix(rnorm(100, 2), ncol=4))
#' y <- rep(c(0,1), each = 25)
#' d <- get_dist_mat(z)
#' z0 <- matrix(rnorm(100),ncol=2)
#' mm_cmds(z0 = z0, D = d, y = y)

mm_cmds <- function(nit = 100, lambda = 0.2, z0, D, y, z){
  N <- dim(z0)[1]
  S <- dim(z0)[2]
  a <- length(unique(y))
  y_indmat <- get_ind_mat(y)
  if(is.null(D)){
      D <- get_dist_mat(z)
  } else {
      D <- as.matrix(D)
  }
  f_ratio <- pseudo_F(mat = z, d = D, trt = y)
  z_temp <- z_up <- z0
  p0 <- get_p(d = D, trt = y)$p
  log_iter_mat <- matrix(0, nrow=0, ncol=6)
  colnames(log_iter_mat) <-
      c('epoch', 'obj', 'obj_mds', 'obj_confr', 'p_z', 'p_0')
  # obj_prev <- 0
  p_prev <- 1
  for(t in 0:nit){
    p_up <- get_p(mat = z_up, trt = y)$p

    if((abs(p_up-p0) >= abs(p_prev-p0)) & (abs(p_prev-p0)<=0.01)){
      print(sprintf('Lambda %.2f ...halt iteration', lambda))
      z_up <- z_prev # revert to prev
      break
    }

    if(lambda==0){
      f_ratio_pred <- f_ratio
    } else {
      list_pair <- pair_by_rank(D=D, z=z_up, y=y) # _0, _z
      ind_f_ratio <- which.min(abs(f_ratio - list_pair[,1]))[1]
      f_ratio_pred <- list_pair[,2][ind_f_ratio]
    }

    z_distmat <- as.matrix(dist(z_up))
    f_diff_nominator <- sum((1 - a * y_indmat * (1+f_ratio_pred*(a-1)/(N-a))) *
                                z_distmat^2)
    delta <- sign(f_diff_nominator)
    obj_conf <- abs(f_diff_nominator)
    obj_mds <- mds_obj(D, z_up)
    obj <- lambda*obj_conf + obj_mds

    print(paste('epoch', t,
                '  lambda', lambda,
                '  total', sprintf(obj, fmt = '%#.2f'),
                '  mds', sprintf(obj_mds, fmt = '%#.2f'),
                '  conf', sprintf(obj_conf, fmt = '%#.2f'),
                '  p_z', sprintf(p_up, fmt = '%#.3f'),
                '  p_0', sprintf(p0, fmt = '%#.3f')
    ))
    log_iter_mat <- rbind(log_iter_mat,
                          c(t, obj, obj_mds, obj_conf, p_up, p0))


    for(i in 1:N){
      z_distmat <- as.matrix(dist(z_up))  # (N,N)
      coeff <- D/z_distmat  # final term in the update
      coeff[is.nan(coeff)] <- 0
      z_diff <- -sweep(x=z_up, MARGIN=2, STATS=as.matrix(z_up[i,]), FUN="-")

      z_temp[i,] <- (1+lambda*delta) * (apply(z_up[y!=y[i],], 2, sum)) +
        (1-lambda*delta*(1+2*f_ratio_pred/(N-2))) *
          (apply(z_up[y==y[i],], 2, sum)) +
        apply(sweep(x=z_diff, MARGIN=1, STATS=coeff[,i], FUN="*"), 2, sum)

      z_temp[i,] <- z_temp[i,] / (N - N*lambda*delta*f_ratio_pred/(N-2))
    } # end z_temp

    z_prev <- z_up
    # obj_prev <- obj_up
    p_prev <- p_up
    z_up <- z_temp
  } # end iteration


  Fz_up <- pseudo_F(mat = z_up, trt = y)
  F0 <- pseudo_F(d = D, trt = y)

  return(list(z = z_up, F_z = Fz_up, F_0 = F0))
}
