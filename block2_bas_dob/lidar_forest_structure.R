# ==============================================================================
#  Processing of 3D LiDAR data to assess forest structure 
# ==============================================================================

# check out the manual of the lidR package: https://r-lidar.github.io/lidRbook/ 

# ===  0. Setup ================================================================

# set up working directory
setwd("~") # add your working directory here! 


# load libraries
# install.packges("lidR")
# install.packages("terra")
# install.packages("sf")
# install.packages("rTwig")
# install.packages('lidRviewer', repos = c('https://r-lidar.r-universe.dev'))


library(lidR)
library(terra)
library(sf)
library(lidRviewer)
library(dplyr)
library(rTwig)

# Data access
url_las <- "https://owncloud.gwdg.de/index.php/s/3z4bYtZ5jdJN8Wl/download"
download.file(url_las, destfile = "uls_goewa.laz", mode = "wb")

url_bi <- "https://cloud.hawk.de/index.php/s/rFb3tsfttpYArko/download"
download.file(url_bi, destfile = "trees_bi.gpkg", mode = "wb")


# load lidar point cloud  
las <- readLAS("uls_goewa.laz")
print(las)
plot(las)

trees_bi <- st_read("trees_bi.gpkg")

# ===  1. Calculate Terrain models =============================================

dem <- rasterize_terrain(las, res = 0.5, algorithm = tin())
dsm <- rasterize_canopy(las, res = 0.5, algorithm = dsmtin(max_edge = 8))
chm <- dsm - dem
chm <- terra::focal(chm, w = 3, fun = mean, na.rm = TRUE) # smoothing results 

par(mfrow= c(1,3))
plot(dem, main = "digital elevation model")
plot(dsm, main = "digital surface model")
plot(chm, main = "canopy heigt model")

#writeRaster(dem, "./data/output/dem.tif", overwrite=TRUE)
#writeRaster(dsm, "./data/output/dsm.tif", overwrite=TRUE)
#writeRaster(chm, "./data/output/chm.tif", overwrite=TRUE)


# === 2. Individual Tree Detection =============================================

## Function for Local Maximum Filter with variable windows size

f <- function(x) {
  y <- 2.6 * (-(exp(-0.08*(x-2)) - 1)) + 3 
  # from https://r-lidar.github.io/lidRbook/itd.html
  y[x < 2] <- 3
  y[x > 20] <- 5
  return(y)
}

heights <- seq(-5,35,0.5)
ws <- f(heights)

par(mfrow= c(1,1))
plot(heights, ws, type = "l",  ylim = c(0,5))

#ttops <- locate_trees(las, lmf(f)) # only run this if you have a fast computer! 
ttops <- locate_trees(chm, lmf(f)) 

# plot results 
plot(chm, col = height.colors(50))
plot(sf::st_geometry(trees_bi), add = TRUE, pch = 2, col ="blue")
plot(sf::st_geometry(ttops), add = TRUE, pch = 3, col = "black")

# 3D plot
las_norm <- normalize_height(las, knnidw()) # normalize point cloud for this vizualisation 
x <- plot(las_norm, bg = "white", size = 4)
add_treetops3d(x, ttops)

#writeVector(vect(ttops), "./data/output/ttops_chm_.gpkg", overwrite=TRUE)

# === 3. Individual Tree Segmentation ==========================================

algo <- dalponte2016(chm, ttops)
las <- segment_trees(las_norm, algo) # segment point cloud
x <- plot(las, bg = "white", size = 4, color = "treeID") # visualize trees
add_treetops3d(x, ttops)

# === 4. Derive Metrics using the Area-based Approach ==========================

r_metr <- pixel_metrics(las, res = 0.5, func = .stdmetrics)
plot(r_metr)



# PRAKASH PART =================================================================

# === 5.Forest structural complexity =========================================
#(Fractal complexity analysis/ voxel-based box-count dimension or box dimension (Db) method)
#The box dimension quantifies structural complexity of point clouds using a fractal box-counting approach. 
#It is defined as the slope of the regression between log box (voxel) count and log inverse box (voxel) size, 
#with higher R² values indicating stronger self-similarity.
#Reliable estimates require high-resolution (≤1 cm) point clouds with minimal occlusion.

library(lidR)
install.packages("devtools")
devtools::install_github("r-lidar/lidRviewer")
library(lidRviewer)
library(dplyr)
# install.packages("rTwig")
library(rTwig)

# Data access
url <- "https://owncloud.gwdg.de/index.php/s/3z4bYtZ5jdJN8Wl/download"
download.file(url, destfile = "uls_goewa.laz", mode = "wb")

# Read data, check and pre-process with lidR
data <- readLAS("uls_goewa.laz")
print(data)
las_check(data) 

las <- normalize_height(las = data, 
                        algorithm = tin(), 
                        use_class = 2)

las_check(las) # check negative outliers

view(las)
            #Rotate with left mouse button
            #Zoom with mouse wheel
            #Pan with right mouse button
            #Keyboard r or g or b to color with RGB
            #Keyboard z to color with Z
            #Keyboard i to color with Intensity
            #Keyboard c to color with Classification
            #Keyboard + or - to change the point size
            #Keyboard l to enable/disable eyes-dome lightning


las@data[Z<0, 1:3] # Here options are either remove all or assign all to 0, However...

# Forest structural complexity (Box dimension)

cloud = las@data[Z>0.5, 1:3] # Here, all points above 0.5 meter and only X,Y,z coordinates 

db <- box_dimension(cloud = cloud, 
                    lowercutoff = 0.01, 
                    rm_int_box = FALSE, 
                    plot = FALSE )
str(db)

# Box Dimension (slope)
db[[2]]$slope
db[[2]]$r.squared # show similarity

# Visualization
# 2D Plot
box_dimension(cloud[, 1:3], plot = "2D")
# 3D Plot
box_dimension(cloud[, 1:3], plot = "3D")



