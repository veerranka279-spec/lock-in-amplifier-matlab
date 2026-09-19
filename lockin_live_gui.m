function lockin_live_gui()
% LOCKIN_LIVE_GUI  Live-running Orthogonal Lock-In Amplifier demo with GUI controls.
% Run this file directly (F5) - it will open a window with Start/Stop and live sliders.

    %% ---------- Fixed system parameters ----------
    fs = 10000;            % Sampling frequency (Hz)
    chunk_size = 50;        % Samples per frame (5 ms per chunk @ fs=10kHz)
    R6 = 1000; C1 = 100e-9;
    fc_hw = 1/(2*pi*R6*C1);
    [b_hw, a_hw] = butter(1, fc_hw/(fs/2));
    fc_sw = 20;
    [b_sw, a_sw] = butter(2, fc_sw/(fs/2));
    window_sec = 0.05;      % scrolling window for raw/X/Y plots
    history_sec = 5;        % how much Magnitude history to keep on screen

    %% ---------- State (persists between timer callbacks) ----------
    st = struct();
    st.fs = fs; st.chunk_size = chunk_size;
    st.b_hw = b_hw; st.a_hw = a_hw; st.zi_hw = zeros(max(length(a_hw),length(b_hw))-1,1);
    st.b_sw = b_sw; st.a_sw = a_sw;
    st.zi_x = zeros(max(length(a_sw),length(b_sw))-1,1);
    st.zi_y = st.zi_x;
    st.sample_idx = 0;      % running sample counter (defines t = sample_idx/fs)

    % Live-adjustable parameters (defaults)
    st.f_target = 1000;     % Hz
    st.A_sig = 0.8;         % V
    st.dc_offset = 1.65;    % V
    st.phase_shift = pi/3;  % rad
    st.noise_level = 0.4;   % std dev of Gaussian noise

    % Rolling history buffers (preallocated, fixed length ring-style via growing cap)
    max_hist_samples = round(history_sec*fs);
    st.t_hist   = nan(1, max_hist_samples);
    st.mag_hist = nan(1, max_hist_samples);
    st.hist_fill = 0; % how many valid samples currently in hist buffers

    %% ---------- Build GUI ----------
    fig = uifigure('Name','Live Orthogonal Lock-In Amplifier','Position',[100 80 1050 800]);

    ax1 = uiaxes(fig,'Position',[60 560 950 200]);
    h_raw = plot(ax1, NaN, NaN, 'r', 'LineWidth',0.8); hold(ax1,'on');
    h_adc = plot(ax1, NaN, NaN, 'b', 'LineWidth',1.2); hold(ax1,'off');
    title(ax1,'1. Hardware Signal Path: Raw vs Conditioned ADC Input (LIVE)');
    xlabel(ax1,'Time (ms)'); ylabel(ax1,'Voltage (V)');
    legend(ax1,{'Raw + Noise','Hardware Filtered'},'Location','northeast');
    grid(ax1,'on');

    ax2 = uiaxes(fig,'Position',[60 320 950 200]);
    h_x = plot(ax2, NaN, NaN, 'b', 'LineWidth',2); hold(ax2,'on');
    h_y = plot(ax2, NaN, NaN, 'm', 'LineWidth',2); hold(ax2,'off');
    title(ax2,'2. Firmware I/Q Filtered Components (LIVE)');
    xlabel(ax2,'Time (ms)'); ylabel(ax2,'Amplitude');
    legend(ax2,{'In-Phase (X)','Quadrature (Y)'},'Location','northeast');
    grid(ax2,'on');

    ax3 = uiaxes(fig,'Position',[60 80 950 200]);
    h_mag = plot(ax3, NaN, NaN, 'g', 'LineWidth',2.5); hold(ax3,'on');
    h_target = yline(ax3, st.A_sig, '--k', 'Target Amplitude');
    title(ax3,'3. Recovered Magnitude R (LIVE)');
    xlabel(ax3,'Time (ms)'); ylabel(ax3,'Extracted Voltage (V)');
    legend(ax3,{'Recovered R','Target'},'Location','northeast');
    grid(ax3,'on'); ylim(ax3,[0, 1.2*st.A_sig]);

    %% ---------- Controls panel ----------
    panel = uipanel(fig,'Title','Live Controls','Position',[60 700 950 90]);

    uilabel(panel,'Position',[10 40 90 22],'Text','Noise level:');
    sld_noise = uislider(panel,'Position',[100 55 180 3],'Limits',[0 2],'Value',st.noise_level);

    uilabel(panel,'Position',[300 40 100 22],'Text','Phase shift (deg):');
    sld_phase = uislider(panel,'Position',[400 55 180 3],'Limits',[0 360], ...
                          'Value', rad2deg(st.phase_shift));

    uilabel(panel,'Position',[600 40 100 22],'Text','Target freq (Hz):');
    edt_freq = uieditfield(panel,'numeric','Position',[700 45 80 22], ...
                            'Value', st.f_target, 'Limits',[10 4000]);

    btn_start = uibutton(panel,'push','Text','Start','Position',[820 45 55 30], ...
                          'BackgroundColor',[0.4 0.8 0.4]);
    btn_stop  = uibutton(panel,'push','Text','Stop','Position',[880 45 55 30], ...
                          'BackgroundColor',[0.9 0.4 0.4],'Enable','off');

    lbl_status = uilabel(fig,'Position',[900 700 140 22],'Text','Status: Stopped', ...
                          'FontWeight','bold');

    %% ---------- Timer: one chunk processed per tick ----------
    t = timer('ExecutionMode','fixedRate', ...
              'Period', chunk_size/fs, ...  % real-time paced: matches real sample duration
              'TimerFcn', @(~,~) onTick());

    btn_start.ButtonPushedFcn = @(~,~) startSim();
    btn_stop.ButtonPushedFcn  = @(~,~) stopSim();
    fig.CloseRequestFcn = @(~,~) onClose();

    %% ---------- Callback functions ----------
    function startSim()
        btn_start.Enable = 'off'; btn_stop.Enable = 'on';
        lbl_status.Text = 'Status: Running';
        start(t);
    end

    function stopSim()
        if strcmp(t.Running,'on'); stop(t); end
        btn_start.Enable = 'on'; btn_stop.Enable = 'off';
        lbl_status.Text = 'Status: Stopped';
    end

    function onClose()
        if isvalid(t)
            if strcmp(t.Running,'on'); stop(t); end
            delete(t);
        end
        delete(fig);
    end

    function onTick()
        % ---- Pull live values from sliders/edit field every tick ----
        st.noise_level = sld_noise.Value;
        st.phase_shift = deg2rad(sld_phase.Value);
        st.f_target = edt_freq.Value;

        idx0 = st.sample_idx;
        t_chunk = (idx0:(idx0+chunk_size-1)) / fs;

        % ---- HARDWARE SIDE ----
        clean_signal = st.A_sig * sin(2*pi*st.f_target*t_chunk + st.phase_shift) + st.dc_offset;
        interference = 0.5 * sin(2*pi*3500*t_chunk);
        random_noise = st.noise_level * randn(size(t_chunk));
        V_in_chunk = clean_signal + interference + random_noise;

        [V_adc_chunk, st.zi_hw] = filter(st.b_hw, st.a_hw, V_in_chunk, st.zi_hw);

        % ---- FIRMWARE SIDE ----
        V_ac_chunk = V_adc_chunk - st.dc_offset;
        ref_X = sin(2*pi*st.f_target*t_chunk);
        ref_Y = cos(2*pi*st.f_target*t_chunk);

        X_raw_chunk = V_ac_chunk .* ref_X;
        Y_raw_chunk = V_ac_chunk .* ref_Y;

        [X_chunk, st.zi_x] = filter(st.b_sw, st.a_sw, X_raw_chunk, st.zi_x);
        [Y_chunk, st.zi_y] = filter(st.b_sw, st.a_sw, Y_raw_chunk, st.zi_y);

        Mag_chunk = sqrt(X_chunk.^2 + Y_chunk.^2) * 2;

        % ---- Update scrolling raw/X/Y plots (only need last `window_sec`) ----
        tt_ms = t_chunk*1000;
        set(h_raw,'XData',tt_ms,'YData',V_in_chunk);
        set(h_adc,'XData',tt_ms,'YData',V_adc_chunk);
        set(h_x,  'XData',tt_ms,'YData',X_chunk);
        set(h_y,  'XData',tt_ms,'YData',Y_chunk);
        xlim(ax1,[tt_ms(1), tt_ms(end)]);
        xlim(ax2,[tt_ms(1), tt_ms(end)]);
        ylim(ax1,[st.dc_offset-3, st.dc_offset+3]);

        % ---- Update magnitude rolling history (ring buffer via shift) ----
        n_new = numel(Mag_chunk);
        st.t_hist   = [st.t_hist(n_new+1:end), t_chunk];
        st.mag_hist = [st.mag_hist(n_new+1:end), Mag_chunk];
        st.hist_fill = min(max_hist_samples, st.hist_fill + n_new);

        valid = ~isnan(st.mag_hist);
        set(h_mag,'XData', st.t_hist(valid)*1000, 'YData', st.mag_hist(valid));
        if any(valid)
            xlim(ax3,[min(st.t_hist(valid)), max(st.t_hist(valid))]*1000 + [0 eps]);
        end
        h_target.Value = st.A_sig; % keep target line in sync if A_sig ever changes

        st.sample_idx = idx0 + chunk_size;
    end

end
