elastic_net_wrapper_rose <- function(data, outcome=NULL, predictors_con=NULL,predictors_cat=NULL, split=80, outer_cv=NULL, stratified=T,scaling=T,
                                     repeated_cv=1,ensr_cv=10,ensr_alphas=seq(0, 1, length = 10),ensr_lambdas=100,seed=404,shuffle=T,
                                     stop_train=NULL,stop_test=NULL,pROSE=0.5,NROSE=NULL){
  # required packages
  require(ensr)
  require(glmnet)
  require(pROC)
  require(caret)
  require(splitTools)
  require(ROSE)
  `%!in%` = Negate(`%in%`)
  
  # combine predictors
  predictors = c(predictors_con,predictors_cat)
  
  # shuffle dataset to lose time contingency for CV
  if (shuffle==T){
    set.seed(seed)
    data = data[sample(nrow(data)),]
  }
  
  # split data into y and x
  y = data[outcome]
  x = data[predictors]
  
  # create list of x and y datasets to be analyzed
  analysis_list = list()
  # split x and y into training and testing data
  if (is.null(outer_cv)==T){
    # performing stratified split
    if(stratified==T){
      # get indices
      set.seed(seed)
      my_train_ind_no_y =  sample(which(y==0), size = split/100*length(which(y==0)))
      set.seed(seed)
      my_train_ind_y =  sample(which(y==1), size = split/100*length(which(y==1)))
      # split data
      y_train = y[c(my_train_ind_no_y,my_train_ind_y),]
      y_test =y[-c(my_train_ind_no_y,my_train_ind_y),]
      x_train = x[c(my_train_ind_no_y,my_train_ind_y),]
      x_test = x[-c(my_train_ind_no_y,my_train_ind_y),]
      # add to analysis list
      analysis_list[[1]] = list(y_train,y_test,x_train,x_test)
    }
    # performing non-stratified split
    else if(stratified==F){
      set.seed(seed)
      my_train_ind =  sample(c(1:nrow(y)), size = split/100*nrow(y))
      y_train = y[c(my_train_ind),]
      y_test =y[-c(my_train_ind),]
      x_train = x[c(my_train_ind),]
      x_test = x[-c(my_train_ind),]
      # add to analysis list
      analysis_list[[1]] = list(y_train,y_test,x_train,x_test)
    }
  }
  # creating datasets for cross-validation
  else {
    if(stratified==T){
      # creating folds
      set.seed(seed)
      folds <- create_folds(as.numeric(unlist(y)),k = outer_cv,type='stratified')
      # creating datasets
      for(nfold in 1:length(folds)){
        y_train <- y[c(folds[[nfold]]), ]
        y_test <- y[-c(folds[[nfold]]), ]
        x_train <- x[c(folds[[nfold]]), ]
        x_test <- x[-c(folds[[nfold]]), ]
        analysis_list[[nfold]] = list(y_train,y_test,x_train,x_test)
      }
    }
    else if(stratified==F){
      set.seed(seed)
      folds <- create_folds(as.numeric(unlist(y)),k = outer_cv,type='basic')
      for(nfold in 1:length(folds)){
        y_train <- y[c(folds[[nfold]]), ]
        y_test <- y[-c(folds[[nfold]]), ]
        x_train <- x[c(folds[[nfold]]), ]
        x_test <- x[-c(folds[[nfold]]), ]
        analysis_list[[nfold]] = list(y_train,y_test,x_train,x_test)
      }
    }
  }
  
  # creating the results dataframe
  results_df = data.frame(matrix(ncol = (11+length(predictors))))
  colnames(results_df) = c('fold','nrow_train','nrow_test','ny_train','ny_test','AUC','sensitivity','specificity',
                           'accuracy','PPV','NPV',predictors)
  
  # Create progress bar
  print('Training and evaluating the models')
  pb = txtProgressBar(min = 0, max = length(analysis_list), initial = 0) 
  
  # Training and testing the elastic net
  for (entry in 1:length(analysis_list)){
    
    # getting the training and testing data
    y_train_entry = analysis_list[[entry]][[1]]
    y_test_entry= analysis_list[[entry]][[2]]
    x_train_entry= analysis_list[[entry]][[3]]
    x_test_entry= analysis_list[[entry]][[4]]
    
    # Stopping if there aren't enough observations in the training data
    if (is.null(stop_train)==F){
      if (sum(as.numeric(as.character(unlist(y_train_entry))))<stop_train){next}
    }
    
    #scaling numeric data
    if (scaling==T){
      for(variable in predictors_con){
        mean_variable = mean(as.numeric(unlist(x_train_entry[,variable])),na.rm=T)
        sd_variable = sd(as.numeric(unlist(x_train_entry[,variable])),na.rm=T)
        x_train_entry[,variable] = (as.numeric(unlist(x_train_entry[,variable]))-mean_variable)/sd_variable
        x_test_entry[,variable] = (as.numeric(unlist(x_test_entry[,variable]))-mean_variable)/sd_variable
      }
    }    
    
    # removing variables with no variance from the training data
    for (name in colnames(x_train_entry)){
      if (length(unique(x_train_entry[,name]))<2){
        x_train_entry = x_train_entry[, !colnames(x_train_entry) %in% c(name)]
        x_test_entry = x_test_entry[, !colnames(x_test_entry) %in% c(name)]
      }
    }
    
    # correcting dummy coded variables
    # identify binary data
    binary_predictors = colnames(x_train_entry)[which(apply(x_train_entry,2,function(x) { all(x %in% 0:1) })==T)]
    binary_predictors = subset(binary_predictors,binary_predictors%!in%colnames(x_train_entry)[grepl('numeric',sapply(x_train_entry,class))])
    
    # transforming to a data matrix
    x_train_entry = data.matrix(x_train_entry)
    x_test_entry = data.matrix(x_test_entry)
    
    # creating dataset for ROSE
    x_train_entry =  data.frame(x_train_entry)
    x_train_entry[,subset(predictors_con,predictors_con%in%colnames(x_train_entry))] = data.frame(lapply(x_train_entry[,subset(predictors_con,predictors_con%in%colnames(x_train_entry))],as.numeric))
    x_train_entry[,subset(predictors_cat,predictors_cat%in%colnames(x_train_entry))] = data.frame(lapply(x_train_entry[,subset(predictors_cat,predictors_cat%in%colnames(x_train_entry))],as.factor))
    y_train_entry = as.factor(y_train_entry)
    
    # correcting unbalanced data with ROSE
    if (is.null(NROSE)==T){NROSE=length(y_train_entry)}
    data_rose = ROSE(y_train_entry~., data=data.frame(cbind(y_train_entry,x_train_entry)),seed=seed,p=pROSE,N=NROSE)$data
    y_train_entry = data.matrix(data_rose[,1])
    x_train_entry = data.matrix(data_rose[,-1])
    
    # correcting dummy coded variables
    x_train_entry[,c(binary_predictors)]<- x_train_entry[,c(binary_predictors)]-1
    x_test_entry[,c(binary_predictors)]<- x_test_entry[,c(binary_predictors)]-1
    
    # finding best lambda and alpha
    
    # creating a variable for storing the crossvalidation results for the alphas and the lambdas
    MSEs <- NULL
    
    # store variables for  ensr
    x_train_entry <<- x_train_entry
    y_train_entry <<- y_train_entry
    ensr_lambdas <<- ensr_lambdas
    ensr_cv <<- ensr_cv
    ensr_alphas <<- ensr_alphas
    
    for (repeated_cv_number in 1:repeated_cv){
      
      # setting the seed
      set.seed(repeated_cv_number)
      # selecting the best alpha and lambda for this seed
      ensr_obj <- ensr(y =data.matrix(y_train_entry), x = x_train_entry,nlambda=ensr_lambdas,nfolds = ensr_cv,
                       alphas = ensr_alphas,family='binomial',standardize = F)
      ensr_obj_summary <- summary(object = ensr_obj)
      
      # storing the results
      MSEs <- cbind(MSEs,ensr_obj_summary$cvm)
    }
    
    # converting the cross validation results to a dataframe
    MSEs <- as.data.frame(MSEs)
    MSEs$rowMeans <- rowMeans(MSEs)
    
    # adding the alphas and lambdas that we used
    # these are the same for every seed!
    MSEs$lambdas <- ensr_obj_summary$lambda
    MSEs$alphas<- ensr_obj_summary$alpha
    MSEs <- MSEs[order(MSEs$rowMeans,decreasing = F), ]
    
    # Selecting the  alpha and the lambda of the best model
    alpha.min <- MSEs$alphas[1]
    lambda.min <- MSEs$lambdas[1]
    
    # fitting the elastic net model and getting the estimates for the variables
    elastic_model <- glmnet(y =data.matrix(y_train_entry), x = x_train_entry, family = 'binomial', alpha = alpha.min,
                            lambda=lambda.min,standardize = F)
    estimates <- elastic_model$beta
    
    # having at least one parameter
    while (length(which(estimates!=0))<1){
      MSEs <- MSEs[-1,]
      lambda.min <- MSEs$lambdas[1]
      alpha.min <- MSEs$alphas[1]
      elastic_model <- glmnet(y =data.matrix(y_train_entry), x = x_train_entry, family = 'binomial',
                              alpha = alpha.min,lambda=lambda.min,standardize = F)
      estimates <- elastic_model$beta
    }
    
    # calculate metrics
    
    # Stopping if there aren't enough observations in the training data
    if (is.null(stop_test)==F){
      if (sum(as.numeric(as.character(unlist(y_test_entry))))<stop_test){next}
    }
    
    # AUC, sensitivity, specificity
    predictions = predict(elastic_model, newx=x_test_entry,type = "response")
    model_roc =  roc(unlist(y_test_entry),as.numeric(predictions),direction="<",quiet=T, levels=c('0','1'))
    model_coords = coords(model_roc,"best", ret=c("threshold", "specificity", "sensitivity"), transpose=FALSE)
    model_auc = auc(model_roc)
    model_spec <- model_coords[2]
    model_sens <- model_coords[3]
    
    # accuracy, PPV, NPV
    predictions_bin = ifelse(predictions>model_coords$threshold,1,0)
    confmatrix <- confusionMatrix(as.factor(predictions_bin),as.factor(unlist(y_test_entry)),positive='1')
    
    # storing metrics
    results_df[entry,'fold']=entry
    results_df[entry,'nrow_train']=nrow(x_train_entry)
    results_df[entry,'nrow_test']=nrow(x_test_entry)
    results_df[entry,'ny_train']=sum(as.numeric(as.character(unlist(y_train_entry))))
    results_df[entry,'ny_test']=sum(as.numeric(as.character(unlist(y_test_entry))))
    results_df[entry,'AUC']=model_auc
    results_df[entry,'sensitivity']=model_sens
    results_df[entry,'specificity']=model_spec
    results_df[entry,'accuracy']=confmatrix$overall[1]
    results_df[entry,'PPV']=confmatrix$byClass[3]
    results_df[entry,'NPV']=confmatrix$byClass[4]
    
    # storing estimates
    for (predictor in predictors){
      index = which(rownames(estimates)==predictor)
      if (length(index)==0){
        results_df[entry,predictor]<- NA
      }
      else{
        results_df[entry,predictor]<- estimates[index]
      }
      
      # updating progress bar
      setTxtProgressBar(pb,entry)
    }
  }
  
  # close progress bar
  close(pb)
  
  # remove stored variables
  rm(x_train_entry,envir = .GlobalEnv)
  rm(y_train_entry,envir = .GlobalEnv)
  rm(ensr_lambdas,envir = .GlobalEnv)
  rm(ensr_cv,envir = .GlobalEnv)
  rm(ensr_alphas,envir = .GlobalEnv)
  # return df
  return(results_df)
}