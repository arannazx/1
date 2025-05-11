
%% 风电场不良数据识别与重构程序
% 数据要求：Excel文件包含时间戳、风速、功率三列，表头为英文（如Time, WindSpeed, Power）

%% 步骤1：导入数据
clc; clear; close all;

% 读取Excel数据（假设文件名为'wind_data.xlsx'，表头为Time, WindSpeed, Power）
data = readtable('wind_power_data.xlsx');

% 转换时间戳格式
data.Time = datetime(data.Time, 'InputFormat', 'dd MM yyyy HH:mm'); % 根据实际格式调整

% 转换为数值数组并处理缺失值
wind_speed = double(data.WindSpeed(:));
power = double(data.Power(:));
time = datetime(data.Time); % 时间列处理

% 数据有效性过滤
valid_idx = ~isnan(wind_speed) & ~isnan(power) & (wind_speed >= 0);
wind_speed = wind_speed(valid_idx);
power = power(valid_idx);
time = time(valid_idx);

% 自动识别基本参数
cut_in_speed = prctile(wind_speed(power > 0), 1); % 切入风速
rated_power = prctile(power, 99.9); % 额定功率
cut_out_speed =25;
fprintf('自动识别参数:\n切入风速=%.2f m/s\n额定功率=%.2f kW\n切出风速=%.2f m/s\n',...
        cut_in_speed, rated_power, cut_out_speed);

%% 步骤2：异常检测（改进的分箱LOESS方法）
bin_width = 0.5; % 风速分箱宽度
bin_edges = 0:bin_width:ceil(max(wind_speed))+5;
bin_idx = discretize(wind_speed, bin_edges);
is_anomaly = false(size(wind_speed));

% 分箱处理异常检测
for bin = 1:max(bin_idx)
    in_bin = bin_idx == bin;
    if sum(in_bin) < 20 % 忽略数据量少的分箱
        continue
    end
    
    try
        % 局部加权回归
        x_bin = wind_speed(in_bin);
        y_bin = power(in_bin);
        span = 0.25; % 平滑系数
        predicted = smooth(x_bin, y_bin, span, 'loess');
        
        % 动态阈值计算
        residuals = y_bin - predicted;
        threshold = 1.5*iqr(residuals)+median(abs(residuals)) ;
        is_anomaly(in_bin) = abs(residuals) > threshold;
    catch
        fprintf('分箱%d处理失败，跳过\n', bin);
    end
end

% 添加物理规则检测
is_anomaly(wind_speed < cut_in_speed & power > 0) = true;
is_anomaly(wind_speed > cut_out_speed & power > 0) = true;
is_anomaly(power < 0 | power > rated_power*1.05) = true;

count=nnz(is_anomaly);
disp(['异常数据',num2str(count)]);

%% 步骤3：物理约束数据重构
reconstructed_power = power;
anomaly_idx = find(is_anomaly);
window_size = 6; % 滑动窗口大小

for i = 1:length(anomaly_idx)
    idx = anomaly_idx(i);
    current_wind = wind_speed(idx);
    
    % 物理规则强制修正
    if current_wind < cut_in_speed || current_wind > cut_out_speed
        reconstructed_power(idx) = 0;
        continue
    end
    
    % 滑动窗口邻近点搜索
    start_idx = max(1, idx - window_size);
    end_idx = min(length(power), idx + window_size);
    window_indices = start_idx:end_idx;
    valid_points = window_indices(~is_anomaly(window_indices));
    
    if length(valid_points) < 5 % 扩大搜索范围
        valid_points = find(~is_anomaly);
    end
    
    % 基于风速邻近点的插值
    [~, sorted_idx] = sort(abs(wind_speed(valid_points) - current_wind));
    nearest_idx = valid_points(sorted_idx(1:min(10,end)));
    
    % 局部线性回归插值
    X = wind_speed(nearest_idx);
    Y = reconstructed_power(nearest_idx);
    valid = Y >= 0 & Y <= rated_power;
    
    if sum(valid) >= 3
        mdl = fitlm(X(valid), Y(valid), 'linear');
        pred = predict(mdl, current_wind);
        reconstructed_power(idx) = max(0, min(pred, rated_power));
    else
        reconstructed_power(idx) = 0; % 安全回退
    end
end

% 最终物理约束
reconstructed_power(reconstructed_power < 0) = 0;
reconstructed_power(reconstructed_power > rated_power) = rated_power;

%% 步骤4：可视化分析
figure('Position', [100 100 1600 800]) % 增大画布尺寸

% 子图1：原始数据功率曲线（包含异常点标记）
subplot(1,2,1)
scatter(wind_speed, power, 10, 'b', 'filled'); hold on
scatter(wind_speed(is_anomaly), power(is_anomaly),...
    20, 'r', 'filled', 'MarkerEdgeColor','k');
xlabel('Wind Speed (m/s)'); ylabel('Power (kW)');
title('原始功率曲线（含异常点）'); grid on
legend('正常数据', '异常数据', 'Location','northwest')

% 子图2：重构后功率曲线
subplot(1,2,2)
scatter(wind_speed, reconstructed_power, 10, 'g', 'filled'); hold on
scatter(wind_speed(anomaly_idx), reconstructed_power(anomaly_idx),...
    20, 'm', 'filled', 'MarkerEdgeColor','k');
xlabel('Wind Speed (m/s)'); ylabel('Power (kW)');
title('重构后功率曲线'); grid on
legend('正常数据', '修正点', 'Location','northwest')

