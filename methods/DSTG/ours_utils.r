
binarize <- function(sc_count){
  sc_count[sc_count > 1] = 1 
  return(sc_count)
}

#extract_dropout-based_genes(rows are genes,cols are samples)
extract_dropout_genes <- function(counts){
  norm_data = M3DropConvertData(counts)
  select_genes = M3DropFeatureSelection(norm_data)
  return(counts[select_genes[,1],])
}

#select variable genes by ANOVA
select_feature <- function(data,label,nf){
  M <- nrow(data); new.label <- label[,1]
  pv1 <- sapply(1:M, function(i){
    mydataframe <- data.frame(y=as.numeric(data[i,]), ig=new.label)
    fit <- aov(y ~ ig, data=mydataframe)
    summary(fit)[[1]][["Pr(>F)"]][1]})
  names(pv1) <- rownames(data)
  pv1.sig <- names(pv1)[order(pv1)[1:nf]]
  egen <- unique(pv1.sig)
  return (egen)
}

generate_spots = function (se_obj, clust_vr,lower = 2, upper = 10, n = 1000, verbose = TRUE) 
{
  if (is(se_obj) != "Seurat") 
    stop("ERROR: se_obj must be a Seurat object!")
  if (!is.character(clust_vr)) 
    stop("ERROR: clust_vr must be a character string!")
  if (!is.numeric(n)) 
    stop("ERROR: n must be an integer!")
  if (!is.logical(verbose)) 
    stop("ERROR: verbose must be a logical object!")
  suppressMessages(require(DropletUtils))
  suppressMessages(require(purrr))
  suppressMessages(require(dplyr))
  suppressMessages(require(tidyr))
  se_obj@meta.data[, clust_vr] <- gsub(pattern = "[[:punct:]]|[[:blank:]]", 
                                       ".", x = se_obj@meta.data[, clust_vr], perl = TRUE)
  print("Generating synthetic test spots...")
  start_gen <- Sys.time()
  pb <- txtProgressBar(min = 0, max = n, style = 3)
  count_mtrx <- as.matrix(se_obj@assays$RNA@counts)
  ds_spots <- lapply(seq_len(n), function(i) {
    cell_pool <- sample(colnames(count_mtrx), sample(x = lower:upper, 
                                                     size = 1))
    pos <- which(colnames(count_mtrx) %in% cell_pool)
    tmp_ds <- se_obj@meta.data[pos, ] %>% mutate(weight = 1)
    name_simp <- paste("spot_", i, sep = "")
    spot_ds <- tmp_ds %>% dplyr::select(all_of(clust_vr), 
                                        weight) %>% dplyr::group_by(!!sym(clust_vr)) %>% 
      dplyr::summarise(sum_weights = sum(weight)) %>% 
      dplyr::ungroup() %>% tidyr::pivot_wider(names_from = all_of(clust_vr), 
                                              values_from = sum_weights) %>% dplyr::mutate(name = name_simp)
    syn_spot <- rowSums(as.matrix(count_mtrx[, cell_pool]))
    sum(syn_spot)
    names_genes <- names(syn_spot)
    if (sum(syn_spot) > 25000) {
      syn_spot_sparse <- DropletUtils::downsampleMatrix(Matrix::Matrix(syn_spot, 
                                                                       sparse = T), prop = 20000/sum(syn_spot))
    }
    else {
      syn_spot_sparse <- Matrix::Matrix(syn_spot, sparse = T)
    }
    rownames(syn_spot_sparse) <- names_genes
    colnames(syn_spot_sparse) <- name_simp
    setTxtProgressBar(pb, i)
    return(list(syn_spot_sparse, spot_ds))
  })
  ds_syn_spots <- purrr::map(ds_spots, 1) %>% base::Reduce(function(m1, 
                                                                    m2) cbind(unlist(m1), unlist(m2)), .)
  ds_spots_metadata <- purrr::map(ds_spots, 2) %>% dplyr::bind_rows() %>% 
    data.frame()
  ds_spots_metadata[is.na(ds_spots_metadata)] <- 0
  lev_mod <- gsub("[\\+|\\ |\\/]", ".", unique(se_obj@meta.data[,clust_vr]))
  colnames(ds_spots_metadata) <- gsub("[\\+|\\ |\\/]", ".", 
                                      colnames(ds_spots_metadata))
  print(sum(lev_mod %in% colnames(ds_spots_metadata)))
  print(length(unique(se_obj@meta.data[,clust_vr])) + 1)
  if (sum(lev_mod %in% colnames(ds_spots_metadata)) == (length(unique(se_obj@meta.data[,clust_vr])) + 1)) {
    ds_spots_metadata <- ds_spots_metadata[, lev_mod]
  }
  else {
    missing_cols <- lev_mod[which(!lev_mod %in% colnames(ds_spots_metadata))]
    ds_spots_metadata[missing_cols] <- 0
    ds_spots_metadata <- ds_spots_metadata[, lev_mod]
  }
  close(pb)
  print(sprintf("Generation of %s test spots took %s mins", 
                n, round(difftime(Sys.time(), start_gen, units = "mins"), 
                         2)))
  print("output consists of a list with two dataframes, this first one has the weighted count matrix and the second has the metadata for each spot")
  return(list(topic_profiles = ds_syn_spots, cell_composition = ds_spots_metadata))
}

#generate "real-ST" for PBMC data (mixed cells randomly with all genes)
#return mixed count(row = genes,col = spot) and composition(row = spot, col = cell type)
generate_realST_allgenes <- function(count, celltype, spot_num=1000,lower_cellnum = 2, upper_cellnum = 10){
  label = data.frame(celltype)
  rownames(label) = colnames(count)
  colnames(label) = 'subclass'
  sc_obj <- Seurat::CreateSeuratObject(counts = count,meta.data=label)
  #' convert scRNA-seq data to pseudo-spatial data                                                                                                                           
  generate_result<-generate_spots(se_obj=sc_obj,clust_vr='subclass',n = spot_num,lower = lower_cellnum,upper = upper_cellnum);
  generate_count <- as.matrix(generate_result[[1]])
  colnames(generate_count)<-paste("real_mixt",1:ncol(generate_count),sep="_");
  generate_comp <- generate_result[[2]]
  comp = generate_comp/rowSums(generate_comp)
  result = list(generate_count,comp)
  names(result) = c('count','comp')
  return(result)
}

#' normalize function
normalize_data <- function(count.list,scale_num = 10000){
  norm.list <- vector('list')
  for ( i in 1:length(count.list)){
    norm.list[[i]] <- as.matrix(Seurat:::NormalizeData.default(count.list[[i]],scale.factor = scale_num))
  }
  return (list(norm.list))}

#' scaling function 
scale_data <- function(count.list,norm.list,hvg.features){
  scale.list <- lapply(norm.list,function(mat){
    Seurat:::ScaleData.default(object = mat, features = hvg.features)})
  scale.list <- lapply(1:length(count.list),function(i){
    return (scale.list[[i]][na.omit(match(rownames(count.list[[i]]),rownames(scale.list[[i]]))),])})
  return (scale.list)}

#' This function takes pseudo-spatial and real-spatial data to identify variable genes         
#' if anova = TRUE, it means that you are running custom data set and this function would 
#' conduct gene selection and pseudo-ST generation from scRNA-seq data.                                                                                   
gen_pseudo_ST <- function(st_count,st_label,dropout_extract = FALSE,spot_num = 1000,
                          HVG_num = 200,combine_feature = FALSE,HVG = FALSE,
                          scale_num = 10000,lower_cellnum,upper_cellnum){
  if(combine_feature){
    feature1 = rownames(extract_dropout_genes(st_count[[1]]))
    print(dim(st_count[[1]]))
    print(length(feature1))
    feature2 = select_feature(st_count[[1]],st_label[[1]],nf = HVG_num)
    print(length(feature2))
    print(dim(st_count[[2]]))
    sel.features = union(feature1,feature2)
    print(length(sel.features))
    st_count_new <- list(st_count[[1]][sel.features,],st_count[[2]][sel.features,])
    print(sprintf('dropout_features:%s',length(feature1)))
    print(sprintf('HVG_features:%s',length(feature2)))
    
  }else if(dropout_extract){
    sel.features <- rownames(extract_dropout_genes(st_count[[1]]))
    st_count_new <- list(st_count[[1]][sel.features,],st_count[[2]][sel.features,])
    print(sprintf('dropout_features:%s',length(sel.features)))
    
  }else if(HVG){
    sel.features <- select_feature(st_count[[1]],st_label[[1]],nf = HVG_num)
    st_count_new <- list(st_count[[1]][sel.features,],st_count[[2]][sel.features,])
    print(sprintf('HVG_features:%s',length(sel.features)))
    
  }else{
    sel.features = rownames(st_count[[1]])
    st_count_new = st_count
  }
  colnames(st_label[[1]]) <- 'subclass'
  tem.t1 <- Seurat::CreateSeuratObject(counts = st_count_new[[1]],meta.data=st_label[[1]]);
  #' convert scRNA-seq data to pseudo-spatial data                                                                                                                           
  test.spot.ls1<-generate_spots(se_obj=tem.t1,clust_vr='subclass',n = spot_num,lower = lower_cellnum,upper = upper_cellnum);
  test.spot.counts1 <- as.matrix(test.spot.ls1[[1]])
  colnames(test.spot.counts1)<-paste("mixt",1:ncol(test.spot.counts1),sep="_");
  test.spot.metadata1 <- test.spot.ls1[[2]]
  
  st_counts <- list(test.spot.counts1,st_count_new[[2]])
  st_labels <- list(test.spot.metadata1/rowSums(test.spot.metadata1))
  st_norm <- normalize_data(st_counts,scale_num = scale_num)[[1]]
  st_scale <- scale_data(st_counts,st_norm,sel.features)
  return (list(st_counts,st_labels,st_norm,st_scale,sel.features))
}

process_data <- function(sc.count,st.count,celltype,spot_num = 1000,real_ST_label = NULL,ST_location = NULL,
                         ST_is_real = FALSE, HVG_num = 200,dropout_extract = FALSE,
                         combine_feature = FALSE,HVG = FALSE,scale_num = 10000,lower_cellnum = 2, upper_cellnum = 10){
  intersect.genes <- intersect(rownames(sc.count),rownames(st.count))
  print(length(intersect.genes))
  sc.count <- sc.count[intersect.genes,]
  st.count <- st.count[intersect.genes,]
  count.list <- list(sc.count,st.count)
  label.list <- list(data.frame(celltype))
  rownames(label.list[[1]]) = colnames(sc.count)

  gen_pST=gen_pseudo_ST(st_count=count.list,
                        st_label=label.list,
                        dropout_extract = dropout_extract,
                        spot_num = spot_num,
                        combine_feature = combine_feature,
                        HVG_num = HVG_num,
                        HVG = HVG,
                        scale_num = scale_num,
                        lower_cellnum = lower_cellnum,
                        upper_cellnum = upper_cellnum)
  st.count <- gen_pST[[1]];
  st.label <- gen_pST[[2]];
  if(ST_is_real){
    st.label[[2]] = real_ST_label
  }else{
    st.label[[2]] <- data.frame(matrix(0L,ncol = length(unique(celltype)),nrow = ncol(st.count[[2]])))
    colnames(st.label[[2]]) = colnames(st.label[[1]])
  }
  st.norm <- gen_pST[[3]];
  st.scale <- gen_pST[[4]];
  variable.genes <- gen_pST[[5]]

  
  #' create data folders
  dir.create('Datadir'); dir.create('Output'); dir.create('DSTG_Result')
  inforDir <- 'Infor_Data'; dir.create(inforDir)
  
  #' save counts data to certain path: 'Datadir'
  write.csv(t(st.count[[1]]),file='Datadir/Pseudo_ST1.csv',quote=F,row.names=T)
  write.csv(t(st.count[[2]]),file='Datadir/Real_ST2.csv',quote=F,row.names=T)
  
  #' save scaled data to certain path: 'Infor_Data'
  write.csv(variable.genes,file=paste0(inforDir,'/Variable_features.csv'),quote=F,row.names=F)
  if(!is.null(ST_location)){
    print('into coordinates')
    d=nn2(as.matrix(ST_location),as.matrix(ST_location),k=2)
    coor = d$nn.idx
    colnames(coor) = c('cell1','cell2')
    write.csv(coor,file=paste0(inforDir,'/mindis_cell_indices.csv'),quote=F,row.names=F)
  }

  
  if (!dir.exists(paste0(inforDir,'/ST_count'))){dir.create(paste0(inforDir,'/ST_count'))}
  if (!dir.exists(paste0(inforDir,'/ST_label'))){dir.create(paste0(inforDir,'/ST_label'))}
  if (!dir.exists(paste0(inforDir,'/ST_norm'))){dir.create(paste0(inforDir,'/ST_norm'))}
  if (!dir.exists(paste0(inforDir,'/ST_scale'))){dir.create(paste0(inforDir,'/ST_scale'))}
  
  for (i in 1:2){
    write.csv(st.count[[i]],file=paste0(inforDir,'/ST_count/ST_count_',i,'.csv'),quote=F)
    write.csv(st.label[[i]],file=paste0(inforDir,'/ST_label/ST_label_',i,'.csv'),quote=F)
    write.csv(st.norm[[i]],file=paste0(inforDir,'/ST_norm/ST_norm_',i,'.csv'),quote=F)
    write.csv(st.scale[[i]],file=paste0(inforDir,'/ST_scale/ST_scale_',i,'.csv'),quote=F)
  }
}


synthetic_performance <- function (test_spots_metadata_mtrx, spot_composition_mtrx) 
{
  if (!is.matrix(test_spots_metadata_mtrx)) 
    stop("ERROR: test_spots_metadata_mtrx must be a matrix object!")
  if (!is.matrix(spot_composition_mtrx)) 
    stop("ERROR: syn_spots_ls must be the list obtained from the function syn_spot_comb_topic_fun().")
  colnames(spot_composition_mtrx) <- gsub(pattern = "[[:punct:]]|[[:blank:]]", 
                                          ".", x = colnames(spot_composition_mtrx), perl = TRUE)
  colnames(test_spots_metadata_mtrx) <- gsub(pattern = "[[:punct:]]|[[:blank:]]", 
                                             ".", x = colnames(test_spots_metadata_mtrx), perl = TRUE)
  suppressMessages(require(philentropy))
  true_jsd_mtrx <- matrix(nrow = nrow(test_spots_metadata_mtrx), 
                          ncol = 1)
  tp <- 0
  tn <- 0
  fp <- 0
  fn <- 0
  mse <- 0
  for (i in seq_len(nrow(test_spots_metadata_mtrx))) {
    x <- rbind(test_spots_metadata_mtrx[i, ], spot_composition_mtrx[i, 
    ])
    if (sum(spot_composition_mtrx[i, ]) > 0) {
      true_jsd_mtrx[i, 1] <- suppressMessages(JSD(x = x, 
                                                  unit = "log2", est.prob = "empirical"))
    }
    else {
      true_jsd_mtrx[i, 1] <- 1
    }
    for (index in colnames(test_spots_metadata_mtrx)) {
      mse = mse + (x[1, index] - x[2, index])^2
      if (x[1, index] > 0 & x[2, index] > 0) {
        tp <- tp + 1
      }
      else if (x[1, index] == 0 & x[2, index] == 0) {
        tn <- tn + 1
      }
      else if (x[1, index] > 0 & x[2, index] == 0) {
        fn <- fn + 1
      }
      else if (x[1, index] == 0 & x[2, index] > 0) {
        fp <- fp + 1
      }
    }
    rm(index)
  }
  rm(i)
  ##calculate RMSE for each cell type
  RMSE = matrix(0L,nrow = 1,ncol = ncol(test_spots_metadata_mtrx))
  all_rmse = 0
  for (i in 1:ncol(test_spots_metadata_mtrx)){
    mse = sum((test_spots_metadata_mtrx[ ,i] - spot_composition_mtrx[ ,i])^2)
    all_rmse = all_rmse + mse
    RMSE[1,i] = sqrt(mse/nrow(test_spots_metadata_mtrx))
    }
  colnames(RMSE) = colnames(test_spots_metadata_mtrx)
  all_rmse = sqrt(all_rmse / (nrow(test_spots_metadata_mtrx) * ncol(test_spots_metadata_mtrx)))
  accuracy <- round((tp + tn)/(tp + tn + fp + fn), 2)
  sensitivity <- round(tp/(tp + fn), 2)
  specificity <- round(tn/(tn + fp), 2)
  precision <- round(tp/(tp + fp), 2)
  recall <- round(tp/(tp + fn), 2)
  F1 <- round(2 * ((precision * recall)/(precision + recall)), 
              2)
  quants_jsd <- round(quantile(matrixStats::rowMins(true_jsd_mtrx, 
                                                    na.rm = TRUE), c(0.25, 0.5, 0.75)), 5)
  cat(sprintf("The following summary statistics are obtained:\n         
                Accuracy: %s,\n              Sensitivity: %s,\n              Specificity: %s,\n              precision: %s,\n              recall: %s,\n              F1 score: %s,\n              
                              JSD quantiles: %s[%s-%s]", 
              accuracy, sensitivity, specificity, precision, recall, 
              F1, quants_jsd[[2]], quants_jsd[[1]], quants_jsd[[3]]), 
      sep = "\n")
  
  cat("raw statistics are returned in the list - TP, TN, FP, FN, JSD quantiles", 
      sep = "\n")
  print(RMSE)
  print(all_rmse)
  return(list(
    JSD = quants_jsd[[2]],
    JSD_all = c(quants_jsd[[2]],quants_jsd[[1]],quants_jsd[[3]]),
    RMSE = RMSE,
    all_rmse = all_rmse
  ))
}
