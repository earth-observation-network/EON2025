# =============================================================================
# Microclimate Warmup
# Point measurements -> spatial result rasters -> model comparison
# =============================================================================
#
# This script is intentionally kept small.
# It shows the minimal technical chain:
#
#   1. Load measurement points
#   2. Load elevation raster
#   3. Select one temperature timestamp
#   4. Extract elevation values at the station locations from the DEM
#   5. Limit the valid output area
#   6. Build a prediction grid from the DEM
#   7. Run four simple model variants
#   8. Evaluate the models with leave-one-out cross-validation
#   9. Calculate RMSE
#  10. Display the result rasters with a common colour scale
#
# Conceptual idea:
#   Point measurements do not automatically become a reliable surface.
#   A model assumption always stands between points and area.
#
# The four model assumptions in this script:
#
#   Voronoi      : nearest station wins
#   IDW          : nearby stations count more than distant stations
#   LM altitude  : temperature is transferred through elevation
#   RF warning   : Random Forest learns spatial/elevation patterns from few points
#
# Required files:
#
#   data/climdata.rds
#   data/DEM1.tif
#
# Required packages:
#
#   sf
#   terra
#   gstat
#   randomForest
#
# =============================================================================


# =============================================================================
# 1. LOAD DATA
# =============================================================================
#
# sf:
#   handles vector data, here the measurement stations with geometry.
#
# terra:
#   handles raster data, here the digital elevation model.
#
# gstat:
#   provides IDW, nearest-neighbour via nmax = 1, and gstat.cv().
#
# randomForest:
#   provides the data-driven comparison model.
#
# No further packages are required.

library(sf)
library(terra)
library(gstat)
library(randomForest)


# Load measurement stations.
# Expected structure:
#   m is an sf object.
#   It contains point geometries and temperature columns.
#
# Important:
#   readRDS() reads a prepared R object.
#   No raw-data import is performed here.

m <- readRDS("data/climdata.rds")


# Load the digital elevation model.
# Expected structure:
#   DEM1.tif is a raster.
#   Each raster cell contains an elevation value.

dem <- rast("data/DEM1.tif")


# Set the layer name explicitly.
# This ensures that the elevation variable is called altitude everywhere later.

names(dem) <- "altitude"


# =============================================================================
# 2. SELECT ONE TEMPERATURE TIMESTAMP
# =============================================================================
#
# The measurement data contain several temperature columns.
# For the warmup, exactly one column is selected.
#
# Advantage:
#   All models work with the same target variable.
#   Differences in the results therefore come from the model assumption,
#   not from different timestamps.

m$temp <- m[["A20230830"]]


# =============================================================================
# 3. ALIGN COORDINATE REFERENCE SYSTEMS
# =============================================================================
#
# Point data and raster data must use the same coordinate reference system.
#
# Why?
#   - Elevation extraction is spatially correct only when CRS matches.
#   - Distances for IDW/Voronoi must be computed in the correct space.
#   - Raster cells and measurement points must be spatially comparable.
#
# The DEM defines the target CRS here.

m <- st_transform(m, crs(dem))


# =============================================================================
# 4. EXTRACT ELEVATION AT THE STATIONS
# =============================================================================
#
# For each measurement station, the elevation value is extracted from the DEM.
#
# Why not use an existing elevation variable?
#   Because station elevation and result raster then come from the same elevation base.
#   This avoids a mismatch between point data and raster model.

m$altitude <- terra::extract(dem, terra::vect(m))$altitude


# =============================================================================
# 5. SELECT VALID MEASUREMENT POINTS
# =============================================================================
#
# For modelling, each station needs:
#
#   temp      : temperature at the selected timestamp
#   altitude  : elevation from the DEM
#
# Stations with missing temperature or missing elevation are removed.

pts <- m[!is.na(m$temp) & !is.na(m$altitude), c("temp", "altitude")]


# =============================================================================
# 6. CREATE THE VALID OUTPUT AREA
# =============================================================================
#
# Interpolation should not be reported arbitrarily far outside the measurement
# network. Therefore, the spatial output is limited to the station area.
#
# Steps:
#
#   st_geometry(pts)
#     keeps only the point geometries.
#
#   st_union(...)
#     combines the points geometrically.
#
#   st_convex_hull(...)
#     builds the convex hull around the stations.
#
#   st_buffer(..., 20)
#     expands this hull by 20 m.
#
# Result:
#   area is the valid statement area for all result rasters.

area <- st_sf(
  geometry = st_buffer(
    st_convex_hull(st_union(st_geometry(pts))),
    20
  )
)


# Clip the DEM to the statement area.
# crop() first reduces the rectangular extent.
# mask() then sets cells outside the exact area to NA.

dem <- crop(dem, vect(area))
dem <- mask(dem, vect(area))


# Set the name again after crop/mask.
# This keeps the later table structure stable.

names(dem) <- "altitude"


# =============================================================================
# 7. BUILD THE PREDICTION GRID FROM THE DEM
# =============================================================================
#
# The models need target locations where values are predicted.
# These target locations are all valid raster cells inside the statement area.
#
# as.data.frame(..., xy = TRUE, cells = TRUE):
#   creates a table from the raster with:
#
#   cell      : raster cell number
#   x         : x-coordinate of the raster cell
#   y         : y-coordinate of the raster cell
#   altitude  : elevation value of the raster cell

grid <- as.data.frame(dem, xy = TRUE, cells = TRUE, na.rm = FALSE)


# The fourth column contains the elevation values.
# It is explicitly named altitude.

names(grid)[4] <- "altitude"


# Keep only valid raster cells.
# Cells outside the statement area have NA and are removed.

grid <- grid[!is.na(grid$altitude), ]


# For gstat, target locations must be represented as point objects.
#
# remove = FALSE:
#   x and y remain available as ordinary table columns.
#   This is needed later for Random Forest.

grid_sf <- st_as_sf(
  grid,
  coords = c("x", "y"),
  crs = st_crs(pts),
  remove = FALSE
)


# =============================================================================
# 8. HELPER FUNCTIONS
# =============================================================================
#
# make_map():
#   Many models return one prediction per valid raster cell.
#   These predictions must be written back to the correct raster-cell positions.
#
#   pred:
#     prediction values in the same order as grid.
#
#   name:
#     name of the result raster.
#
#   r <- dem:
#     the result raster inherits geometry, resolution, extent, and mask
#     from the prepared DEM.
#
#   values(r)[grid$cell] <- pred:
#     predictions are written into the corresponding raster cells.

make_map <- function(pred, name) {
  r <- dem
  values(r) <- NA
  values(r)[grid$cell] <- pred
  names(r) <- name
  r
}


# rmse_fun():
#   calculates the root mean squared error.
#
#   e:
#     error vector, i.e. observed minus predicted values or the reverse.
#
#   e * e:
#     squares the errors.
#
#   mean(...):
#     averages the squared errors.
#
#   sqrt(...):
#     takes the square root.
#
# Interpretation:
#   smaller RMSE = smaller back-prediction errors at the station locations.

rmse_fun <- function(e) {
  sqrt(mean(e * e, na.rm = TRUE))
}


# =============================================================================
# 9. ADD COORDINATES FOR RANDOM FOREST
# =============================================================================
#
# Random Forest is deliberately used as a warning example with spatial coordinates.
# Therefore, x and y are extracted from the point geometries as ordinary columns.
#
# Conceptual point:
#   RF can then use spatial position directly.
#   With only a few points, this may look plausible but can be strongly adapted
#   to the existing point layout.

xy <- st_coordinates(pts)
pts$x <- xy[, 1]
pts$y <- xy[, 2]


# =============================================================================
# 10. MODEL 1: LM ALTITUDE
# =============================================================================
#
# Linear model:
#
#   temp ~ altitude
#
# Meaning:
#   temperature is estimated as a linear function of elevation.
#
# Model assumption:
#   elevation explains part of the temperature differences.
#
# Result:
#   the result raster follows the elevation raster.

fit_lm <- lm(temp ~ altitude, data = st_drop_geometry(pts))


# predict(dem, fit_lm):
#   applies the elevation model to every valid raster cell of the DEM.
#
# Requirement:
#   the raster contains a variable named exactly altitude.

map_lm <- predict(dem, fit_lm)
names(map_lm) <- "LM_altitude"


# =============================================================================
# 11. MODEL 2: VORONOI / NEAREST STATION
# =============================================================================
#
# Voronoi is calculated here as a nearest-neighbour variant.
#
# Technically:
#   gstat::idw(..., nmax = 1)
#
# Meaning of nmax = 1:
#   for each raster cell, only the nearest station is used.
#
# Model assumption:
#   the nearest measurement point is responsible for the cell.
#
# Result:
#   hard station areas without smoothing.

vor_df <- gstat::idw(
  temp ~ 1,
  locations = pts,
  newdata = grid_sf,
  nmax = 1
)


# Write the predictions back to a raster.

map_vor <- make_map(vor_df$var1.pred, "Voronoi")


# =============================================================================
# 12. MODEL 3: IDW
# =============================================================================
#
# IDW = inverse distance weighting.
#
# Basic idea:
#   nearby stations count more than distant stations.
#
# Technical setting:
#   nmax = 4
#
# Meaning:
#   for each raster cell, only the four nearest stations are used.
#
# Model assumption:
#   temperature is transferred locally through spatial proximity.
#
# Result:
#   a smoothed but locally constrained result raster.

idw_df <- gstat::idw(
  temp ~ 1,
  locations = pts,
  newdata = grid_sf,
  nmax = 4
)


# Write the IDW predictions back to a raster.

map_idw <- make_map(idw_df$var1.pred, "IDW")


# =============================================================================
# 13. MODEL 4: RANDOM FOREST WARNING
# =============================================================================
#
# Random Forest receives three predictors:
#
#   x
#   y
#   altitude
#
# Meaning:
#   the model can combine spatial position and elevation in a data-driven way.
#
# Why warning?
#   With only a few measurement points, RF can produce spatial patterns that look
#   convincing. These patterns may, however, be strongly shaped by the point layout.
#
# Conceptual point:
#   a low error value does not automatically imply a robust result surface.

fit_rf <- randomForest(
  temp ~ x + y + altitude,
  data = st_drop_geometry(pts),
  ntree = 200
)


# Predict for all valid raster cells in grid.
# grid contains x, y, and altitude and therefore matches the RF predictors.

rf_pred <- predict(fit_rf, newdata = grid)


# Write the RF predictions back to a raster.

map_rf <- make_map(rf_pred, "RF_warning")


# =============================================================================
# 14. VALIDATION: LEAVE-ONE-OUT CROSS-VALIDATION
# =============================================================================
#
# Goal:
#   evaluate how well the models back-predict known stations.
#
# Principle:
#   one station is left out.
#   the model is recalculated with the remaining stations.
#   the left-out station is predicted.
#   the error is stored.
#
# Important:
#   this evaluates point predictions at station locations.
#   it does not automatically prove the quality of the whole result surface.


# -----------------------------------------------------------------------------
# 14a. LOOCV for LM and RF
# -----------------------------------------------------------------------------
#
# For LM and RF, the leave-one-out logic is written out explicitly.
# This is clearer didactically than hiding it in a special function.

lm_cv <- rep(NA, nrow(pts))
rf_cv <- rep(NA, nrow(pts))


# Loop over all stations.
# i is the station that is left out.

for (i in 1:nrow(pts)) {

  # Training data:
  # all stations except station i.
  train <- pts[-i, ]

  # Test data:
  # only station i.
  test <- pts[i, ]

  # Refit LM without the left-out station.
  fit_lm_i <- lm(temp ~ altitude, data = st_drop_geometry(train))

  # Predict temperature at the left-out station with the LM.
  lm_cv[i] <- predict(fit_lm_i, newdata = st_drop_geometry(test))

  # Refit RF without the left-out station.
  fit_rf_i <- randomForest(
    temp ~ x + y + altitude,
    data = st_drop_geometry(train),
    ntree = 200
  )

  # Predict temperature at the left-out station with RF.
  rf_cv[i] <- predict(fit_rf_i, newdata = st_drop_geometry(test))
}


# -----------------------------------------------------------------------------
# 14b. LOOCV for Voronoi and IDW
# -----------------------------------------------------------------------------
#
# gstat.cv() performs the leave-one-out evaluation for gstat models.
#
# Crucial point:
#   validation must use the same neighbourhood structure as the result map.
#
#   Voronoi:
#     nmax = 1
#
#   IDW:
#     nmax = 4

vor_model <- gstat::gstat(
  formula = temp ~ 1,
  locations = pts,
  nmax = 1,
  set = list(idp = 2)
)

vor_cv <- gstat::gstat.cv(vor_model, nfold = nrow(pts))


idw_model <- gstat::gstat(
  formula = temp ~ 1,
  locations = pts,
  nmax = 4,
  set = list(idp = 2)
)

idw_cv <- gstat::gstat.cv(idw_model, nfold = nrow(pts))


# -----------------------------------------------------------------------------
# 14c. RMSE table
# -----------------------------------------------------------------------------
#
# An RMSE is calculated for each model.
#
# Interpretation:
#   smaller RMSE = better back-prediction of the left-out stations.
#
# Limitation:
#   RMSE alone does not say whether the spatial result is conceptually plausible.

rmse <- data.frame(
  model = c("LM altitude", "Voronoi", "IDW", "RF warning"),
  RMSE = c(
    rmse_fun(pts$temp - lm_cv),
    rmse_fun(vor_cv$residual),
    rmse_fun(idw_cv$residual),
    rmse_fun(pts$temp - rf_cv)
  )
)


# =============================================================================
# 15. DISPLAY RESULT RASTERS
# =============================================================================
#
# The four result rasters are displayed together.
#
# Important:
#   all use the same colour scale.
#   This makes the spatial patterns comparable.
#
# Measurement points are overlaid.
# This shows which result structure is supported by which station layout.

maps <- c(map_vor, map_idw, map_lm, map_rf)


# Common colour range:
#   observed temperature values minus/plus 1 degree.
#
# This prevents each panel from looking artificially plausible or dramatic
# through its own scaling.

z <- range(c(pts$temp - 1, pts$temp + 1), na.rm = TRUE)


# 2 x 2 panel for the four result rasters.

par(mfrow = c(2, 2))


# Plot each raster.
# Then add the measurement stations as black points.

for (i in 1:nlyr(maps)) {
  plot(maps[[i]], range = z, main = names(maps)[i])
  points(pts, pch = 19, cex = 0.8)
}


# Reset plot layout.

par(mfrow = c(1, 1))


# Print RMSE table.
# This table is the entry point into model criticism.

print(rmse)


# =============================================================================
# END
# =============================================================================
#
# How to read the results:
#
#   Voronoi:
#     hard station areas
#
#   IDW:
#     local neighbourhood
#
#   LM altitude:
#     elevation relationship
#
#   RF warning:
#     data-driven spatial/elevation partition
#
# Main conclusion:
#   A spatial result from point measurements is always a modelled statement.
#   It must fit the data situation, the statement area, and the conceptual
#   model assumption.
# =============================================================================
