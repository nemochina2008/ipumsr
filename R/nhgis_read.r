# This file is part of the Minnesota Population Center's ripums.
# For copyright and licensing information, see the NOTICE and LICENSE files
# in this project's top-level directory, and also on-line at:
#   https://github.com/mnpopcenter/ripums


#' Read data from an NHGIS extract
#'
#' Reads a dataset downloaded from the NHGIS extract system. Relies on csv files
#' (with or without the extra header row).
#'
#' @return \code{read_nhgis} returns a \code{tbl_df} with only the tabular data,
#' \code{read_nhgis_sf} returns a \code{sf} object with data and the shapes, and
#' \code{read_nhgis_sp} returns a \code{SpatialPolygonsDataFrame} with data and
#' shapes.
#' @param data_file Filepath to the data (either the .zip file directly
#'   downloaded from the webiste, or the path to the unzipped .csv file).
#' @param shape_file Filepath to the shape files (either the .zip
#'   file directly downloaded from the webiste, or the path to the unzipped
#'   files).
#' @param data_layer For .zip extracts with multiple datasets, the name of the
#'   data to load. Accepts a character vector specifying the file name, or
#'  \code{\link{dplyr_select_style}} conventions. Data layer must uniquely identify
#'  a dataset.
#' @param shape_layer (Defaults to using the same value as data_layer) Specification
#'   of which shape files to load using the same semantics as \code{data_layer}. Can
#'   load multiple shape files, which will be combined.
#' @param verbose Logical, indicating whether to print progress information to
#'   console.
#' @examples
#' \dontrun{
#' data <- read_nhgis("nhgis0001_csv.zip", "nhgis0001_shp.zip")
#' }
#' @family ipums_read
#' @export
read_nhgis <- function(
  data_file,
  data_layer = NULL,
  verbose = TRUE
) {
  data_layer <- enquo(data_layer)

  # Read data files ----
  data_is_zip <- stringr::str_sub(data_file, -4) == ".zip"
  if (data_is_zip) {
    csv_name <- find_files_in_zip(data_file, "csv", data_layer)
    cb_ddi_info <- try(read_ipums_codebook(data_file, !!data_layer), silent = TRUE)
  } else {
    cb_name <- stringr::str_replace(data_file, "\\.csv$", "_codebook.txt")
    cb_ddi_info <- try(read_ipums_codebook(cb_name), silent = TRUE)
  }

  if (class(cb_ddi_info) == "try-error") cb_ddi_info <- nhgis_empty_ddi

  if (verbose) cat(ipums_conditions(cb_ddi_info))

  # Read data
  if (verbose) cat("\n\nReading data file...\n")
  if (data_is_zip) {
    data <- readr::read_csv(
      unz(data_file, csv_name),
      col_types = readr::cols(.default = "c"),
      locale = ipums_locale)
  } else {
    data <- readr::read_csv(
      data_file,
      col_types = readr::cols(.default = "c"),
      locale = ipums_locale
    )
  }

  # If extract is NHGIS's "enhanced" csvs with an extra header row,
  # then remove the first row.
  # (determine by checking if the first row is entirely character
  # values that can't be converted to numeric)
  first_row <- readr::type_convert(data[1, ], col_types = readr::cols(), locale = ipums_locale)
  first_row_char <- purrr::map_lgl(first_row, rlang::is_character)
  if (all(first_row_char)) data <- data[-1, ]

  data <- readr::type_convert(data, col_types = readr::cols(), locale = ipums_locale)

  data <- set_ipums_var_attributes(data, cb_ddi_info$var_info, FALSE)
  data <- set_ipums_df_attributes(data, cb_ddi_info)
  data
}

#' @rdname read_nhgis
#' @export
read_nhgis_sf <- function(
  data_file,
  shape_file,
  data_layer = NULL,
  shape_layer = data_layer,
  verbose = TRUE
) {
  data <- read_nhgis(data_file, !!enquo(data_layer), verbose)

  shape_layer <- enquo(shape_layer)
  if (quo_text(shape_layer) == "data_layer") shape_layer <- data_layer
  if (verbose) cat("Reading geography...\n")

  sf_data <- read_ipums_sf(shape_file, !!shape_layer)

  # Only join on vars that are in both and are called "GISJOIN*"
  join_vars <- intersect(names(data), names(sf_data))
  join_vars <- stringr::str_subset(join_vars, "GISJOIN.*")

  # Drop overlapping vars besides join var from shape file
  drop_vars <- dplyr::intersect(names(data), names(sf_data))
  drop_vars <- dplyr::setdiff(drop_vars, join_vars)
  sf_data <- dplyr::select(sf_data, -one_of(drop_vars))

  # Avoid a warning by adding attributes from the join_vars in data to
  # join_vars in sf_data
  purrr::walk(join_vars, function(vvv) {
    attributes(sf_data[[vvv]]) <<- attributes(data[[vvv]])
  })

  # Coerce to data.frame to avoid sf#414 (fixed in development version of sf)
  data <- dplyr::full_join(as.data.frame(sf_data), as.data.frame(data), by = join_vars)
  data <- sf::st_as_sf(tibble::as_tibble(data))

  # Check if any data rows are missing (merge failures where not in shape file)
  if (verbose) {
    missing_in_shape <- purrr::map_lgl(data$geometry, is.null)
    if (any(missing_in_shape)) {
      gis_join_failures <- data$GISJOIN[missing_in_shape]
      message(paste0(
        "There are ", sum(missing_in_shape), " rows of data that ",
        "have data but no geography. This can happen because:\n  Shape files ",
        "do not include some census geographies such as 'Crews of Vessels' ",
        "tracts that do not have a defined area\n  Shape files have been simplified ",
        "which sometimes drops entire geographies (especially small ones)."
      ))
    }
  }
  data
}

#' @rdname read_nhgis
#' @export
read_nhgis_sp <- function(
  data_file,
  shape_file,
  data_layer = NULL,
  shape_layer = data_layer,
  verbose = TRUE
) {
  data <- read_nhgis(data_file, !!enquo(data_layer), verbose)

  shape_layer <- enquo(shape_layer)
  if (quo_text(shape_layer) == "data_layer") shape_layer <- data_layer
  if (verbose) cat("Reading geography...\n")

  sf_data <- read_ipums_sp(shape_file, !!shape_layer)

  # Only join on vars that are in both and are called "GISJOIN*"
  join_vars <- intersect(names(data), names(sf_data@data))
  join_vars <- stringr::str_subset(join_vars, "GISJOIN.*")

  # Drop overlapping vars besides join var from shape file
  drop_vars <- dplyr::intersect(names(data), names(sf_data))
  drop_vars <- dplyr::setdiff(drop_vars, join_vars)
  sf_data@data <- dplyr::select(sf_data@data, -one_of(drop_vars))

  out <- sp::merge(sf_data, data, by = join_vars, all.x = TRUE)

  # Check if any data rows are missing (merge failures where not in shape file)
  if (verbose) {
    missing_in_shape <- dplyr::anti_join(
      dplyr::select(data, one_of(join_vars)),
      dplyr::select(out@data, one_of(join_vars)),
      by = join_vars
    )
    if (nrow(missing_in_shape) > 0) {
      gis_join_failures <- purrr::pmap_chr(missing_in_shape, function(...) paste(..., sep = "-"))
      message(paste0(
        "There are ", nrow(missing_in_shape), " rows of data that ",
        "have data but no geography. This can happen because:\n  Shape files ",
        "do not include some census geographies such as 'Crews of Vessels' ",
        "tracts that do not have a defined area\n  Shape files have been simplified ",
        "which sometimes drops entire geographies (especially small ones)."
      ))
    }
  }
  out
}



# Fills in a default condition if we can't find codebook for nhgis
nhgis_empty_ddi <- make_ddi(
  file_type = "rectangular",
  conditions = paste0(
    "Use of NHGIS data is subject to conditions, including that ",
    "publications and research which employ NHGIS data should cite it ",
    "appropiately. Please see www.nhgis.org for more information."
  )
)
