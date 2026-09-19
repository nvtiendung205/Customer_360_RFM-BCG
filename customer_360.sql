select * from customer_registered
select * from customer_transaction

select    STR_TO_DATE(Purchase_Date, '%m/%d/%Y') AS Date, Sum(GMV) AS Total_GMV, Count(Transaction_ID) AS Total_Transaction, Count(DISTINCT CustomerID) AS Total_Customer
from customer_transaction
group by STR_TO_DATE(Purchase_Date, '%m/%d/%Y');


SELECT
    SUM(t.GMV) AS Total_GMV,
    COUNT(t.Transaction_ID) AS Total_Transaction,
    COUNT(DISTINCT t.CustomerID) AS Total_Customer,
    YEAR(STR_TO_DATE(r.created_date, '%m/%d/%Y')) AS Year
FROM customer_transaction t
JOIN customer_registered r ON t.CustomerID = r.ID
WHERE t.CustomerID <> 0
GROUP BY YEAR(STR_TO_DATE(r.created_date, '%m/%d/%Y'));



with RFM as(
    select t.CustomerID,
            round(datediff(str_to_date('2022-09-01', '%Y-%m-%d'), min(str_to_date(r.created_date, '%m/%d/%Y'))) / 365.0, 2) as Contract_age, #Độ tuổi hợp đồng
            datediff(str_to_date('2022-09-01', '%Y-%m-%d'), str_to_date(max(t.Purchase_Date),'%m/%d/%Y')) as Recency,#thời gian mua gần nhất
            (count(*) / greatest(datediff(str_to_date('2022-09-01', '%Y-%m-%d'), min(str_to_date(r.created_date, '%m/%d/%Y'))) / 365.0, 1.0)) as Frequency,#tần suất mua hàng theo từng năm
            (sum(t.GMV) / greatest(datediff(str_to_date('2022-09-01', '%Y-%m-%d'), min(str_to_date(r.created_date, '%m/%d/%Y'))) / 365.0, 1.0)) as Monetary #giá trị mua theo từng năm
    from customer_transaction t
    join customer_registered r on t.CustomerID = r.ID
    where t.CustomerID <> 0
    group by t.CustomerID
        ),
#row_number() cho từng cột Recency, Frequency, Monetary
RFM_rn as(
    select *,
        row_number() over(order by Recency asc) as rn_recency,
        row_number() over(order by Frequency asc) as rn_frequency,
        row_number() over(order by Monetary asc) as rn_monetary
    from RFM
),
# tính các giá trị Q1, Q2, Q3 CHO RECENCY
IQR_recency as (
    select min(recency) as min_r,
        (select recency from RFM_rn where rn_recency = round((select max(rn_recency) * 0.25 from RFM_rn),0)) as q1_recency,
        (select recency from RFM_rn where rn_recency = round((select max(rn_recency) * 0.5 from RFM_rn),0)) as q2_recency,
        (select recency from RFM_rn where rn_recency = round((select max(rn_recency) * 0.75 from RFM_rn),0)) as q3_recency
    from RFM_rn
         ),
# tính` các giá trị Q1, Q2, Q3 CHO FREQUENCY
IQR_frequency as (
    select min(frequency) as min_f,
        (select frequency from RFM_rn where rn_frequency = round((select max(rn_frequency) * 0.25 from RFM_rn),0)) as q1_frequency,
        (select frequency from RFM_rn where rn_frequency = round((select max(rn_frequency) * 0.5 from RFM_rn),0)) as q2_frequency,
        (select frequency from RFM_rn where rn_frequency = round((select max(rn_frequency) * 0.75 from RFM_rn),0)) as q3_frequency
    from RFM_rn
         ),
# tính các giá trị Q1, Q2, Q3 CHO MONETARY
IQR_monetary as (
    select min(monetary) as min_m,
        (select monetary from RFM_rn where rn_monetary = round((select max(rn_monetary) * 0.25 from RFM_rn),0)) as q1_monetary,
        (select monetary from RFM_rn where rn_monetary = round((select max(rn_monetary) * 0.5 from RFM_rn),0)) as q2_monetary,
        (select monetary from RFM_rn where rn_monetary = round((select max(rn_monetary) * 0.75 from RFM_rn),0)) as q3_monetary
    from RFM_rn
         ),

IQR_scale as(
select rn.CustomerID, rn.Contract_age, rn.Recency, rn.Frequency, rn.Monetary,
       case
           when r.min_r <= rn.Recency and rn.Recency < r.q1_recency then 4
           when r.q1_recency <= rn.Recency and rn.Recency < r.q2_recency then 3
           when r.q2_recency <= rn.Recency and rn.Recency < r. q3_recency then 2
           else 1 end as R_Scale,
       case
            when f.min_f <= rn.Frequency and rn.Frequency < f.q1_frequency then 1
            when f.q1_frequency <= rn.Frequency and rn.Frequency < f.q2_frequency then 2
            when f.q2_frequency <= rn.Frequency and rn.Frequency < f. q3_frequency then 3
            else 4 end as F_Scale,
       case
            when m.min_m <= rn.Monetary and rn.Monetary < m.q1_monetary then 1
            when m.q1_monetary <= rn.Monetary and rn.Monetary < m.q2_monetary then 2
            when m.q2_monetary <= rn.Monetary and rn.Monetary < m. q3_monetary then 3
            else 4 end as M_Scale
from RFM_rn rn
cross join IQR_recency r
cross join IQR_frequency f
cross join IQR_monetary m
         ),
-- TẠO BẢNG BCG: Gán nhãn và đếm số lượng khách hàng theo từng tổ hợp RFM
BCG as (
    select
        concat(R_Scale, F_Scale, M_Scale) as rfm,
        count(distinct CustomerID) as total_customers,
        case
            -- 1. Star: Phải đồng thời đạt R cao (3,4), F cao (3,4) và M cao (3,4)
            when R_Scale >= 3 and F_Scale >= 3 and M_Scale >= 3 then 'Star'

            -- 2. Question Mark: Chi tiêu cao (M >= 3) nhưng hoặc mua ít (F <= 2) HOẶC đã lâu không quay lại (R <= 2)
            when (F_Scale <= 2 and M_Scale >= 3)
              or (R_Scale <= 2 and F_Scale >= 3 and M_Scale >= 3) then 'Question Mark'

            -- 3. Cash Cow: F cao (3,4) và M thấp (1,2)
            when F_Scale >= 3 and M_Scale <= 2 then 'Cash Cow'

            -- 4. Dog: F thấp (1,2) và M thấp (1,2)
            else 'Dog'
        end as rfm_segmentation
    from IQR_scale
    group by
        concat(R_Scale, F_Scale, M_Scale),
        case
            when R_Scale >= 3 and F_Scale >= 3 and M_Scale >= 3 then 'Star'
            when (F_Scale <= 2 and M_Scale >= 3)
              or (R_Scale <= 2 and F_Scale >= 3 and M_Scale >= 3) then 'Question Mark'
            when F_Scale >= 3 and M_Scale <= 2 then 'Cash Cow'
            else 'Dog'
        end
)

-- BƯỚC CUỐI: Tổng hợp danh sách tổ hợp điểm và đếm tổng số khách hàng từng nhóm
select
    rfm_segmentation as RFM_Segmentation,
    group_concat(rfm order by rfm desc separator ', ') as RFM_List,
    sum(total_customers) as Total_Customers
from BCG
group by rfm_segmentation;





