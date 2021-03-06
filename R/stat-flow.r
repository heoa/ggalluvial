#' Flow positions
#' 
#' Given a dataset with alluvial structure, \code{stat_flow} calculates the
#' centroids (\code{x} and \code{y}) and weights (heights; \code{ymin} and
#' \code{ymax}) of alluvial flows between each pair of adjacent axes.
#' @template stat-aesthetics
#' 

#' @import ggplot2
#' @family alluvial stat layers
#' @seealso \code{\link[ggplot2]{layer}} for additional arguments and
#'   \code{\link{geom_alluvium}} and
#'   \code{\link{geom_flow}} for the corresponding geoms.
#' @inheritParams stat_stratum
#' @param aes.bind Whether to prioritize aesthetics before axes (other than the
#'   index axis) when ordering the lodes within each stratum. Defaults to FALSE.
#' @example inst/examples/ex-stat-flow.r
#' @export
stat_flow <- function(mapping = NULL,
                      data = NULL,
                      geom = "flow",
                      position = "identity",
                      decreasing = NA,
                      reverse = TRUE,
                      aes.bind = FALSE,
                      na.rm = FALSE,
                      show.legend = NA,
                      inherit.aes = TRUE,
                      ...) {
  layer(
    stat = StatFlow,
    data = data,
    mapping = mapping,
    geom = geom,
    position = position,
    show.legend = show.legend,
    inherit.aes = inherit.aes,
    params = list(
      decreasing = decreasing,
      reverse = reverse,
      aes.bind = aes.bind,
      na.rm = na.rm,
      ...
    )
  )
}

#' @rdname ggalluvial-ggproto
#' @usage NULL
#' @export
StatFlow <- ggproto(
  "StatFlow", Stat,
  
  required_aes = c("x"),
  
  setup_data = function(data, params) {
    
    # assign 'alluvium' to 'stratum' if 'stratum' not provided
    if (is.null(data$stratum) & !is.null(data$alluvium)) {
      data <- transform(data, stratum = alluvium)
    }
    
    # assign uniform weight if not provided
    if (is.null(data$weight)) {
      data$weight <- rep(1, nrow(data))
    } else if (any(is.na(data$weight))) {
      stop("Data contains NA weights.")
    }
    
    type <- get_alluvial_type(data)
    if (type == "none") {
      stop("Data is not in a recognized alluvial form ",
           "(see `help(is_alluvial)` for details).")
    }
    
    if (params$na.rm) {
      data <- na.omit(object = data)
    } else {
      data <- na_keep(data = data, type = type)
    }
    
    # ensure that data is in lode form
    if (type == "alluvia") {
      axis_ind <- get_axes(names(data))
      data <- to_lodes(data = data, axes = axis_ind)
      # positioning requires numeric 'x'
      data <- dplyr::arrange(data, x, stratum, alluvium)
      data$x <- contiguate(data$x)
    }
    
    data
  },
  
  compute_panel = function(self, data, scales,
                           decreasing = NA, reverse = TRUE,
                           aes.bind = FALSE) {
    
    # aesthetics
    aesthetics <- setdiff(names(data),
                          c("weight", "PANEL", "group",
                            "alluvium", "x", "stratum"))
    
    # sort within axes by weight according to 'decreasing' parameter
    if (!is.na(decreasing)) {
      deposits <- aggregate(x = data$weight * (1 - decreasing * 2),
                            by = data[, c("x", "stratum"), drop = FALSE],
                            FUN = sum)
      names(deposits)[3] <- "deposit"
    }
    # sort within axes by stratum according to 'reverse' parameter
    arr_fun <- if (reverse) dplyr::desc else identity
    
    # identify aesthetics that vary within strata (at "fissures")
    n_lodes <- dplyr::n_distinct(data[, c("x", "stratum")])
    fissure_aes <- aesthetics[which(sapply(aesthetics, function(x) {
      dplyr::n_distinct(data[, c("x", "stratum", x)])
    }) > n_lodes)]
    data$fissure <- if (length(fissure_aes) == 0) {
      1
    } else {
      interaction(data[, rev(fissure_aes)], drop = TRUE)
    }
    
    # stack starts and ends of flows, using 'alluvium' to link them
    x_ran <- range(data$x)
    data$alluvium <- as.numeric(as.factor(data$alluvium))
    alluvium_max <- max(data$alluvium)
    data <- dplyr::bind_rows(
      transform(dplyr::filter(data, x != x_ran[2]),
                alluvium = alluvium + alluvium_max * (as.numeric(x) - 1),
                link = as.numeric(x),
                side = I("start")),
      transform(dplyr::filter(data, x != x_ran[1]),
                alluvium = alluvium + alluvium_max * (as.numeric(x) - 2),
                link = as.numeric(x) - 1,
                side = I("end"))
    )
    data$side <- factor(data$side, levels = c("start", "end"))
    stopifnot(all(table(data$alluvium) == 2))
    
    # flag flows between common pairs of strata and of aesthetics
    for (var in c("stratum", "fissure")) {
      flow_var <- paste0("flow_", var)
      data <- match_sides(data, var, flow_var)
      data[[flow_var]] <- arr_fun(data[[flow_var]])
    }
    data$alluvium <- as.numeric(interaction(data[, c("flow_stratum",
                                                     "flow_fissure")],
                                            drop = TRUE))
    # aggregate alluvial segments within flows
    group_cols <- setdiff(names(data), c("weight", "group"))
    dots <- lapply(group_cols, as.symbol)
    data <- as.data.frame(dplyr::summarize(dplyr::group_by_(data, .dots = dots),
                                           weight = sum(weight)))
    stopifnot(all(table(data$alluvium) == 2))
    data <- transform(data,
                      group = alluvium)
    
    # sort in preparation for calculating cumulative weights
    if (!is.na(decreasing)) {
      data <- merge(data, deposits, all.x = TRUE, all.y = FALSE)
    } else {
      data$deposit <- arr_fun(data$stratum)
    }
    sort_fields <- c(
      "link", "x",
      "deposit",
      if (aes.bind) {
        c("flow_fissure", "flow_stratum")
      } else {
        c("flow_stratum", "flow_fissure")
      },
      "alluvium", "side"
    )
    data <- data[do.call(order, data[, sort_fields]), ]
    # calculate cumulative weights
    data$y <- NA
    for (ll in unique(data$link)) for (ss in unique(data$side)) {
      ww <- which(data$link == ll & data$side == ss)
      data$y[ww] <- cumsum(data$weight[ww]) - data$weight[ww] / 2
    }
    # calculate y bounds
    data <- transform(data,
                      deposit = NULL,
                      fissure = NULL,
                      flow_fissure = NULL,
                      flow_stratum = NULL,
                      link = NULL,
                      ymin = y - weight / 2,
                      ymax = y + weight / 2)
    
    # arrange data by aesthetics for consistent (reverse) z-ordering
    data <- z_order_colors(data)
    
    data
  }
)

match_sides <- function(data, var, var_col) {
  adj <- tidyr::spread_(data[, c("alluvium", "link", "side", var)],
                        key = "side", value = var)
  adj[[var_col]] <- interaction(adj$link, adj$start, adj$end, drop = TRUE)
  merge(data,
        adj[, c("alluvium", var_col)],
        by = "alluvium", all.x = TRUE, all.y = FALSE)
}
