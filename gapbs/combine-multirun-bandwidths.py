import sys
import pandas as pd
from scipy import stats

filename = sys.argv[1]
df = pd.read_csv(filename)
workloads = df['Name'].drop_duplicates()
#df = df.groupby(["Number", "Name", "Type", "Function"], as_index=False).agg("sum")
#df = df.groupby(["Number", "Name", "Type", "Function"], as_index=False).apply(stats.gmean)
df['t gmean' ] = df.groupby(["Name","Function"], as_index=False)['Time Elapsed'].transform(stats.gmean)
df['l gmean' ] = df.groupby(["Name","Function"], as_index=False)['Read BW'].transform(stats.gmean)
df['s gmean'] = df.groupby(["Name","Function"], as_index=False)['Write BW'].transform(stats.gmean)
final_df = df[["Name","Function","t gmean","l gmean","s gmean"]].drop_duplicates()
#df = df.groupby(["Number", "Name", "Type", "Function"], sort=False, as_index=False).agg("sum")
final_df.to_csv(filename, index=False)
