# Libraries ---------------------------------------------------------------
library(tidyverse)
library(tidymodels)
library(vroom)
library(embed)
library(doParallel)
cl <- makeCluster(parallel::detectCores() - 1)  # use all but one core
registerDoParallel(cl)



# Load data ---------------------------------------------------------------
train_data <- vroom("train.csv", show_col_types = FALSE) %>%
  mutate(Cover_Type = as.factor(Cover_Type))
test_data <- vroom("test.csv", show_col_types = FALSE)

# Recipe -----------------------------------------------------------------
svm_recipe <- recipe(Cover_Type ~ ., data = train_data) %>%
  step_other(all_nominal_predictors(), threshold = 0.01) %>%  # combine rare categories (<1%)
  step_dummy(all_nominal_predictors()) %>%                    # one-hot encode categorical variables
  step_zv(all_predictors()) %>%                               # remove zero-variance predictors
  step_normalize(all_numeric_predictors())                    # normalize numeric features

# Model -------------------------------------------------------------------
svm_model <- svm_rbf(
  cost = tune(),
  rbf_sigma = tune()
) %>%
  set_engine("kernlab") %>%
  set_mode("classification")

# Workflow ---------------------------------------------------------------
svm_workflow <- workflow() %>%
  add_recipe(svm_recipe) %>%
  add_model(svm_model)

# Tuning Grid ------------------------------------------------------------
svm_grid <- grid_random(
  cost(range = c(-3, 3)),
  rbf_sigma(range = c(-3, 3)),
  size = 10   # try 10 random combos instead of full grid
)


# Cross-validation -------------------------------------------------------
folds <- vfold_cv(train_data, v = 3)

# Tune the Model ---------------------------------------------------------
svm_results <- svm_workflow %>%
  tune_grid(
    resamples = folds,
    grid = svm_grid,
    metrics = metric_set(roc_auc),
    control = control_grid(verbose = TRUE, parallel_over = "resamples")
  )


stopCluster(cl)


# Select Best Parameters -------------------------------------------------
bestTune <- svm_results %>%
  select_best(metric = "roc_auc")

# Finalize Workflow and Fit ----------------------------------------------
final_svm_wf <- svm_workflow %>%
  finalize_workflow(bestTune) %>%
  fit(data = train_data)

# Predict on Test Set ----------------------------------------------------
svm_predictions <- final_svm_wf %>%
  predict(new_data = test_data, type = "prob")

# Get Predicted Class (highest probability) -------------------------------
submission <- svm_predictions %>%
  bind_cols(test_data) %>%
  mutate(Cover_Type = colnames(select(., starts_with(".pred_")))[
    max.col(select(., starts_with(".pred_")), ties.method = "first")
  ]) %>%
  mutate(Cover_Type = str_remove(Cover_Type, "^\\.pred_")) %>%  # remove ".pred_" prefix
  select(Id, Cover_Type)

submission$Id <- as.integer(as.numeric(submission$Id))

# Save Results -----------------------------------------------------------
write.csv(submission, "SVM_final.csv", quote = FALSE, row.names = FALSE)

